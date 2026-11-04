#!/usr/bin/env python3
"""Own AstroTops records and the shared Ceratops check-result interface.

The maintained producer contract is adopted from docs/result_records.py.tmpl.
Runners emit actual outcomes into the shared per-worktree current-results file;
the SDLC executor owns their input scope, identity and qualification level.
Explicit final-file calls also support the public controlled-command probe.
Existing portable source/tag build and delivery APIs remain repository-owned
until the shared lifecycle exposes public artifact-receipt routing. Current
group evidence and at most two unreferenced runs remain bounded.
"""

from __future__ import annotations

import argparse
import copy
import datetime
import fnmatch
import hashlib
import importlib.metadata
import json
import os
import pathlib
import platform
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass
from typing import Any

VALIDATION_SCHEMA = "astrotops-repository-validation.v1"
RESULT_SCHEMA = "astrotops-repository-tests.v1"
GROUP_SCHEMA = "astrotops-test-group-result.v1"
BUILD_SCHEMA = "astrotops-build-record.v1"
_EXCLUDED_SOURCE_PREFIXES = (".build/", ".test-results/")
_SAFE_TAG = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$")
_ARTIFACT_TYPE = re.compile(r"^[a-z][a-z0-9]*(?:-[a-z0-9]+)*$")
_ANDROID_PACKAGE = re.compile(
    r"^[A-Za-z][A-Za-z0-9_]*(?:\.[A-Za-z][A-Za-z0-9_]*)+$"
)
_ANDROID_COMPONENT = re.compile(
    r"^[A-Za-z][A-Za-z0-9_.]*/[A-Za-z][A-Za-z0-9_.]*$"
)
_REMOTE_APK_PATH = re.compile(r"^/[A-Za-z0-9._~+/=-]+/base\.apk$")
CommandRunner = Callable[[list[str]], subprocess.CompletedProcess[str]]


def _git(repo_root: pathlib.Path, *arguments: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    """Run Git without a shell and return UTF-8 text output."""

    return subprocess.run(
        ["git", "-C", str(repo_root), *arguments],
        check=check,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def _sha256(path: pathlib.Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _digest_json(value: object) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _portable_files(repo_root: pathlib.Path) -> list[str]:
    listing = _git(repo_root, "ls-files", "--cached", "--others", "--exclude-standard", "-z").stdout.split("\0")
    return sorted(
        path
        for path in listing
        if path and not path.replace("\\", "/").startswith(_EXCLUDED_SOURCE_PREFIXES)
    )


def _source_digest(repo_root: pathlib.Path, relative_paths: Iterable[str] | None = None) -> str:
    paths = sorted(set(relative_paths or _portable_files(repo_root)))
    digest = hashlib.sha256()
    for relative in paths:
        normalized = relative.replace("\\", "/")
        if normalized.startswith(_EXCLUDED_SOURCE_PREFIXES):
            continue
        path = repo_root / relative
        digest.update(normalized.encode("utf-8"))
        digest.update(b"\0")
        if path.is_file():
            digest.update(path.read_bytes())
        else:
            digest.update(b"<missing>")
        digest.update(b"\0")
    return digest.hexdigest()


def _source_dirty_paths(repo_root: pathlib.Path) -> list[str]:
    """Return non-result working-tree paths that prevent portable recording."""

    output = _git(repo_root, "status", "--porcelain=v1", "--untracked-files=all").stdout
    dirty: list[str] = []
    for line in output.splitlines():
        if len(line) < 4:
            continue
        relative = line[3:].split(" -> ")[-1].replace("\\", "/")
        if relative.startswith(_EXCLUDED_SOURCE_PREFIXES):
            continue
        dirty.append(relative)
    return sorted(set(dirty))


@dataclass(frozen=True)
class SourceIdentity:
    """Exact source state tested by one runner invocation."""

    commit: str
    digest: str
    exact_tags: tuple[str, ...]
    dirty_paths: tuple[str, ...]

    def portable(self) -> dict[str, object]:
        return {
            "commit": self.commit,
            "digest": self.digest,
            "exactTags": list(self.exact_tags),
            "dirty": bool(self.dirty_paths),
        }


@dataclass(frozen=True)
class ArtifactIdentity:
    """Immutable-tag version and exact package bytes for delivery reuse."""

    version: str
    source_commit: str
    path: str
    sha256: str
    length: int

    def portable(self) -> dict[str, object]:
        return {
            "schema": BUILD_SCHEMA,
            "version": self.version,
            "sourceCommit": self.source_commit,
            "artifactPath": self.path,
            "artifactSha256": self.sha256,
            "artifactLength": self.length,
        }


def resolve_source_identity(repo_root: pathlib.Path) -> SourceIdentity:
    """Resolve current bytes, latest source commit, exact tags, and dirtiness."""

    repo_root = repo_root.resolve(strict=True)
    commit = _git(
        repo_root,
        "log",
        "-1",
        "--format=%H",
        "--",
        ".",
        ":(exclude).build/**",
        ":(exclude).test-results/**",
    ).stdout.strip()
    if not commit:
        raise ValueError("The repository has no source commit outside result directories.")
    tags = tuple(
        sorted(filter(None, _git(repo_root, "tag", "--points-at", commit).stdout.splitlines()))
    )
    return SourceIdentity(
        commit=commit,
        digest=_source_digest(repo_root),
        exact_tags=tags,
        dirty_paths=tuple(_source_dirty_paths(repo_root)),
    )


def resolve_artifact_identity(
    repo_root: pathlib.Path,
    source: SourceIdentity,
    source_tag: str | None,
    artifact: pathlib.Path | None,
) -> ArtifactIdentity | None:
    """Validate an optional candidate artifact against an exact source tag."""

    if (source_tag is None) != (artifact is None):
        raise ValueError("--source-tag and --artifact must be supplied together.")
    if source_tag is None or artifact is None:
        return None
    if not _SAFE_TAG.fullmatch(source_tag):
        raise ValueError("The source tag contains unsupported characters.")
    tagged_commit = _git(repo_root, "rev-list", "-n", "1", source_tag).stdout.strip()
    if tagged_commit != source.commit:
        comparison = _git(
            repo_root,
            "diff",
            "--quiet",
            tagged_commit,
            "--",
            ".",
            ":(exclude).build/**",
            ":(exclude).test-results/**",
            check=False,
        )
        if comparison.returncode:
            raise ValueError(
                f"Source tag {source_tag!r} resolves to {tagged_commit}, and current source bytes differ."
            )
    artifact = artifact.expanduser().resolve(strict=True)
    artifact_root = (repo_root / ".build" / "artifacts").resolve()
    try:
        relative = artifact.relative_to(artifact_root).as_posix()
    except ValueError as error:
        raise ValueError("Candidate artifacts must be stored under .build/artifacts.") from error
    return ArtifactIdentity(
        version=source_tag,
        source_commit=tagged_commit,
        path=f".build/artifacts/{relative}",
        sha256=_sha256(artifact),
        length=artifact.stat().st_size,
    )


class ResultStore:
    """Atomic, bounded owner for portable results and ignored evidence."""

    def __init__(self, repo_root: pathlib.Path, source: SourceIdentity, *, record: bool) -> None:
        self.repo_root = repo_root.resolve(strict=True)
        self.source = source
        self.record = record
        self.result_root = self.repo_root / ".test-results"
        self.group_root = self.result_root / "groups"
        self.evidence_root = self.result_root / "evidence"
        if record and source.dirty_paths:
            rendered = ", ".join(source.dirty_paths[:8])
            suffix = " ..." if len(source.dirty_paths) > 8 else ""
            raise ValueError(f"Portable results require committed source; dirty paths: {rendered}{suffix}")

    def atomic_json(self, path: pathlib.Path, value: object) -> None:
        """Replace one JSON record and remove its owned staging file."""

        if not self.record:
            return
        resolved_root = self.repo_root.resolve()
        resolved_path = path.resolve()
        try:
            resolved_path.relative_to(resolved_root)
        except ValueError as error:
            raise ValueError("Portable records must remain inside the repository.") from error
        path.parent.mkdir(parents=True, exist_ok=True)
        staging: pathlib.Path | None = None
        try:
            with tempfile.NamedTemporaryFile(
                mode="w",
                encoding="utf-8",
                newline="\n",
                dir=path.parent,
                prefix=f".{path.name}.",
                suffix=".tmp",
                delete=False,
            ) as stream:
                staging = pathlib.Path(stream.name)
                json.dump(value, stream, indent=2, sort_keys=True)
                stream.write("\n")
            staging.replace(path)
        finally:
            if staging is not None:
                staging.unlink(missing_ok=True)

    def begin_evidence_run(self, run_id: str, *, keep: set[str] | None = None) -> pathlib.Path:
        """Create current evidence without removing an applicable result's images."""

        run_root = self.evidence_root / run_id
        run_root.mkdir(parents=True, exist_ok=True)
        self.prune_evidence(keep={run_id, *(keep or ())})
        return run_root

    def prune_evidence(self, *, keep: set[str] | None = None) -> None:
        """Keep current group evidence plus at most two unreferenced run folders."""

        if not self.evidence_root.is_dir():
            return
        keep = set(keep or ())
        directories = sorted(
            (path for path in self.evidence_root.iterdir() if path.is_dir()),
            key=lambda path: (path.stat().st_mtime_ns, path.name),
            reverse=True,
        )
        retained = set(keep)
        limit = max(3, len(retained) + 2)
        for path in directories:
            if path.name in retained:
                continue
            if len(retained) < limit:
                retained.add(path.name)
                continue
            for child in sorted(path.rglob("*"), reverse=True):
                if child.is_file() or child.is_symlink():
                    child.unlink()
                elif child.is_dir():
                    child.rmdir()
            path.rmdir()

    def write_group(self, group_id: str, value: dict[str, object]) -> pathlib.Path:
        path = self.group_root / f"{group_id}.json"
        self.atomic_json(path, value)
        return path

    def write_report(self, value: dict[str, object]) -> pathlib.Path:
        path = self.result_root / "tests.json"
        self.atomic_json(path, value)
        return path

    def write_validation(self, value: dict[str, object]) -> pathlib.Path:
        """Replace the latest tracked repository-validation result."""

        path = self.result_root / "validation.json"
        self.atomic_json(path, value)
        return path

    def build_path(self, artifact: ArtifactIdentity) -> pathlib.Path:
        """Return the portable metadata path owned by one source-tag version."""

        safe_version = re.sub(r"[^A-Za-z0-9._-]", "_", artifact.version)
        return self.repo_root / ".build" / "builds" / f"{safe_version}.json"

    def write_build(self, artifact: ArtifactIdentity, source_digest: str) -> pathlib.Path:
        path = self.build_path(artifact)
        value = {
            **artifact.portable(),
            "sourceDigest": source_digest,
            "approval": None,
        }
        self.atomic_json(path, value)
        return path


def group_fingerprint(
    repo_root: pathlib.Path,
    group_id: str,
    owned_paths: Iterable[str],
    environment: dict[str, object],
    artifact: ArtifactIdentity | None,
) -> str:
    """Bind reuse to group-owned bytes, runner environment, and artifact."""

    payload = {
        "group": group_id,
        "sourceDigest": _source_digest(repo_root, owned_paths),
        "environment": environment,
        "artifact": artifact.portable() if artifact else None,
    }
    return _digest_json(payload)


def build_result(
    repo_root: pathlib.Path,
    artifact: pathlib.Path,
    artifact_type: str,
) -> dict[str, object]:
    """Describe exact completed package bytes in the Ceratops build schema."""

    if not _ARTIFACT_TYPE.fullmatch(artifact_type):
        raise ValueError("artifact type must use lower-case kebab syntax")
    repo_root = repo_root.resolve(strict=True)
    artifact = artifact.expanduser().resolve(strict=True)
    artifact_root = (repo_root / ".build" / "artifacts").resolve(strict=True)
    try:
        relative = artifact.relative_to(artifact_root).as_posix()
    except ValueError as error:
        raise ValueError("build artifacts must remain under .build/artifacts") from error
    if artifact.stat().st_size < 1:
        raise ValueError("build artifact is empty")
    return {
        "schema": "ceratops-build-result.v1",
        "status": "passed",
        "artifact": {
            "type": artifact_type,
            "path": f".build/artifacts/{relative}",
            "sha256": _sha256(artifact),
            "size": artifact.stat().st_size,
        },
    }


def _run_command(arguments: list[str]) -> subprocess.CompletedProcess[str]:
    """Run one deployment command without a shell or inherited output."""

    return subprocess.run(
        arguments,
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
    )


def _command_output(result: subprocess.CompletedProcess[str]) -> str:
    return "\n".join(part.strip() for part in (result.stdout, result.stderr) if part.strip())


def _require_command(
    result: subprocess.CompletedProcess[str],
    action: str,
) -> str:
    """Reject nonzero or semantically empty ADB outcomes with bounded diagnostics."""

    output = _command_output(result)
    if result.returncode != 0:
        raise ValueError(f"{action} failed: {output[:512] or f'exit {result.returncode}'}")
    return output


def _installed_apk_hash(
    adb_executable: str,
    device: str,
    package: str,
    run: CommandRunner,
) -> str | None:
    """Return the exact installed base APK hash, or None when absent."""

    path_result = run(
        [adb_executable, "-s", device, "shell", "pm", "path", package]
    )
    output = _require_command(path_result, "query installed package")
    paths = [
        line.removeprefix("package:").strip()
        for line in output.splitlines()
        if line.startswith("package:")
    ]
    if not paths:
        return None
    if len(paths) != 1 or not _REMOTE_APK_PATH.fullmatch(paths[0]):
        raise ValueError("installed package did not expose one safe base APK path")
    hash_result = run(
        [adb_executable, "-s", device, "shell", "sha256sum", paths[0]]
    )
    hash_output = _require_command(hash_result, "hash installed package")
    fields = hash_output.split()
    if len(fields) < 2 or not re.fullmatch(r"[0-9a-f]{64}", fields[0]):
        raise ValueError("installed package did not produce a valid SHA-256")
    return fields[0]


def _adb_device_states(
    adb_executable: str,
    run: CommandRunner,
) -> dict[str, str]:
    """Return exact ADB serial states without assuming a transport type."""

    result = run([adb_executable, "devices"])
    output = _require_command(result, "list Android devices")
    states: dict[str, str] = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 2 and fields[0] != "List":
            states[fields[0]] = fields[1]
    return states


def _mdns_endpoint(
    adb_executable: str,
    device: str,
    run: CommandRunner,
) -> str | None:
    """Resolve an ADB secure-mDNS serial to its advertised network endpoint."""

    if "._adb-tls-connect._tcp" not in device:
        return None
    result = run([adb_executable, "mdns", "services"])
    output = _require_command(result, "discover Android mDNS services")
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 3 and f"{fields[0]}.{fields[1]}" == device:
            return fields[2]
    return None


def _ready_adb_target(
    adb_executable: str,
    device: str,
    run: CommandRunner,
) -> str:
    """Reuse a connected serial or connect a missing network endpoint."""

    states = _adb_device_states(adb_executable, run)
    if device in states:
        if states[device] != "device":
            raise ValueError(f"ADB target is not ready: {device} ({states[device]})")
        return device

    endpoint = _mdns_endpoint(adb_executable, device, run)
    if endpoint is None and (":" in device or "." in device):
        endpoint = device
    if endpoint is None:
        raise ValueError(f"ADB serial is not connected: {device}")

    connect = run([adb_executable, "connect", endpoint])
    connect_output = _require_command(connect, "connect Android device")
    if not any(
        marker in connect_output.lower()
        for marker in ("connected to", "already connected to")
    ):
        raise ValueError(f"ADB did not establish the requested connection: {connect_output[:512]}")
    states = _adb_device_states(adb_executable, run)
    active_target = endpoint if endpoint in states else device
    if states.get(active_target) != "device":
        raise ValueError(f"ADB target did not become ready: {active_target}")
    return active_target


def android_deploy_result(
    repo_root: pathlib.Path,
    *,
    adb_executable: str,
    device: str,
    package: str,
    activity: str,
    artifact: pathlib.Path,
    artifact_type: str,
    run: CommandRunner = _run_command,
) -> dict[str, object]:
    """Install only changed APK bytes, launch them, and emit one deployment receipt.

    A previous successful install can be resumed safely after receipt loss: the
    on-device base APK is hashed first and ``adb install`` is skipped when those
    bytes already match. Connection and launch output are checked because ADB
    can return exit code zero while reporting a failed connection in text.
    """

    if not device.strip() or any(ord(character) < 32 for character in device):
        raise ValueError("device must be a nonempty printable ADB target")
    if not _ANDROID_PACKAGE.fullmatch(package):
        raise ValueError("package must be a dotted Android identifier")
    if not _ANDROID_COMPONENT.fullmatch(activity) or not activity.startswith(package + "/"):
        raise ValueError("activity must be a component inside the selected package")
    build = build_result(repo_root, artifact, artifact_type)
    descriptor = build["artifact"]
    if not isinstance(descriptor, dict):
        raise ValueError("artifact descriptor is unavailable")

    active_target = _ready_adb_target(adb_executable, device, run)

    expected_hash = str(descriptor["sha256"])
    installed_hash = _installed_apk_hash(
        adb_executable, active_target, package, run
    )
    if installed_hash != expected_hash:
        install = run(
            [
                adb_executable,
                "-s",
                active_target,
                "install",
                "-r",
                str(artifact.expanduser().resolve(strict=True)),
            ]
        )
        install_output = _require_command(install, "install Android package")
        if not any(line.strip() == "Success" for line in install_output.splitlines()):
            raise ValueError(f"ADB did not confirm installation: {install_output[:512]}")
        installed_hash = _installed_apk_hash(
            adb_executable, active_target, package, run
        )
    if installed_hash != expected_hash:
        raise ValueError(
            f"installed APK hash mismatch: expected={expected_hash} actual={installed_hash}"
        )

    launch = run(
        [
            adb_executable,
            "-s",
            active_target,
            "shell",
            "am",
            "start",
            "-W",
            "-n",
            activity,
        ]
    )
    launch_output = _require_command(launch, "launch Android package")
    if not any(line.strip() == "Status: ok" for line in launch_output.splitlines()):
        raise ValueError(f"Android did not confirm a successful launch: {launch_output[:512]}")
    return {
        "schema": "ceratops-deployment-result.v1",
        "status": "passed",
        "target": active_target,
        "artifact": descriptor,
    }



CHECK_RESULT_SCHEMA = "ceratops-repository-check-result.v1"
CONTRACT_SCHEMA = "ceratops-test-result-contract.v1"
CHECK_CONTEXT_ENV = "CERATOPS_REPOSITORY_CHECK_CONTEXT"
CHECK_CONTEXT_SCHEMA = "ceratops-repository-check-inputs.v1"
IDENTITY_FIELDS = ("result_id", "candidate_id", "check_id", "check_version")


def canonical(value: Any) -> bytes:
    """Serialize finite, unambiguous JSON directly to the selected final file."""
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def _object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ValueError("duplicate JSON field")
        value[key] = item
    return value


def _nonfinite(value: str) -> Any:
    raise ValueError("nonfinite JSON value: " + value)


def result_path(value: pathlib.Path) -> pathlib.Path:
    """Reject redirected output; the operation owner selects this final path."""
    path = value.absolute()
    for part in (path, *path.parents):
        try:
            metadata = part.lstat()
        except FileNotFoundError:
            continue
        # lstat handles junctions without following them on the Python 3.11 baseline.
        if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, "st_reparse_tag", None) == getattr(stat, "IO_REPARSE_TAG_MOUNT_POINT", -1):
            raise ValueError("result path must not contain a link")
    if path.exists() and (not path.is_file() or path.stat().st_nlink != 1):
        raise ValueError("result path must be a single regular file")
    return path


def read_result(path: pathlib.Path) -> tuple[bool, Any]:
    """Only unparsable/unaccepted bytes can be repaired; I/O errors propagate."""
    try:
        raw = path.read_bytes()
    except FileNotFoundError:
        return False, None
    try:
        value = json.loads(raw, object_pairs_hook=_object, parse_constant=_nonfinite)
        canonical(value)
    except (ValueError, UnicodeError, RecursionError):
        return True, None
    return True, value


def write_result(path: pathlib.Path, value: dict[str, Any], *, exclusive: bool) -> None:
    """Flush the final file without creating a staging sibling or result copy."""
    raw = canonical(value)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("xb" if exclusive else "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    if path.read_bytes() != raw or read_result(path)[1] != value:
        raise ValueError("result changed during writing")


CURRENT_RESULTS_SCHEMA = "ceratops-current-check-results.v1"


class CurrentCheckResults:
    """Keep one latest outcome per check/target in this worktree's single file.

    The calling thread serializes commands in its worktree; there is no worktree
    lock. A fixed in-process file protects previously saved outcomes while the
    next complete JSON document is flushed and replaced. Inputs are deduplicated
    inside this document, never in additional manifest or history files.
    """

    def __init__(self, root: pathlib.Path) -> None:
        self.root = root.resolve()
        command = ["git", "-C", str(self.root), "rev-parse", "--path-format=absolute", "--git-common-dir"]
        try:
            completed = subprocess.run(command, cwd=self.root, capture_output=True, text=True, check=False)
        except OSError as exc:
            raise ValueError(f"Cannot locate check results for {self.root}: command={command!r}; "
                             f"runtime={shutil.which('git') or '<unavailable>'}; cwd={self.root}; "
                             f"exit=<unavailable: not launched>; stdout=<empty>; stderr=<empty>; cause={exc}") from exc
        if completed.returncode:
            raise ValueError(f"Cannot locate check results: command={command!r}; cwd={self.root}; "
                             f"runtime={shutil.which('git') or '<unavailable>'}; exit={completed.returncode}; "
                             f"stdout={completed.stdout or '<empty>'}; stderr={completed.stderr or '<empty>'}")
        self.common = pathlib.Path(completed.stdout.strip())
        identity = hashlib.sha256(os.path.normcase(str(self.root)).encode()).hexdigest()
        self.path = result_path(self.common / "ceratops/results/repository-checks" / identity / "check_results.json")
        self.worktree = {"id": identity, "path": str(self.root)}
        self.pending = result_path(self.path.with_name(".check_results.in_process.json"))
        # A partial replacement is never acceptance. The last complete file
        # remains authoritative until os.replace succeeds.
        self.pending.unlink(missing_ok=True)
        self._stamp: tuple[int, int, int] | None = None
        self.value: dict[str, Any] = {}
        self._refresh()

    def _refresh(self) -> None:
        try:
            info = self.path.stat()
        except FileNotFoundError:
            self._stamp = None
            self.value = {"schema": CURRENT_RESULTS_SCHEMA, "worktree": self.worktree,
                          "inputGroups": {}, "entries": {}}
            return
        stamp = (info.st_mtime_ns, info.st_size, info.st_ino)
        if stamp == self._stamp:
            return
        if info.st_size > 64 * 1024 * 1024:
            raise ValueError(f"Current check results exceed 64 MiB: {self.path}")
        value = read_result(self.path)[1]
        if (not isinstance(value, dict) or set(value) != {"schema", "worktree", "inputGroups", "entries"}
                or value["schema"] != CURRENT_RESULTS_SCHEMA or value["worktree"] != self.worktree
                or not isinstance(value["inputGroups"], dict) or not isinstance(value["entries"], dict)):
            raise ValueError(f"Current check results are incomplete or belong to another worktree: {self.path}")
        for key, inputs in value["inputGroups"].items():
            if not isinstance(inputs, dict) or key != hashlib.sha256(canonical(inputs)).hexdigest():
                raise ValueError(f"Saved check inputs changed: {self.path}")
        for key, entry in value["entries"].items():
            if (not isinstance(entry, dict) or set(entry) != {"kind", "check_id", "target", "record"}
                    or key != self._key(entry["kind"], entry["check_id"], entry["target"])
                    or not isinstance(entry["record"], dict)):
                raise ValueError(f"Saved check entry is incomplete: {self.path}")
            self._expand(entry["record"], value["inputGroups"])
        self.value, self._stamp = value, stamp

    @staticmethod
    def _key(kind: str, check_id: str, target: Mapping[str, Any]) -> str:
        if not isinstance(kind, str) or not kind or not isinstance(check_id, str) or not check_id or not isinstance(target, dict):
            raise ValueError("A current result requires its check kind, identity and target.")
        return hashlib.sha256(canonical([kind, check_id, target])).hexdigest()

    @staticmethod
    def _expand(record: Mapping[str, Any], groups: Mapping[str, Any]) -> dict[str, Any]:
        expanded = copy.deepcopy(dict(record))
        for field, name in (("inputGroup", "inputs"), ("checkGroup", "check_inputs")):
            if field not in expanded:
                continue
            key = expanded.pop(field)
            if key not in groups:
                raise ValueError("Current result names missing saved inputs.")
            if name == "inputs":
                expanded[name] = copy.deepcopy(groups[key])
            else:
                expanded["inputs"][name] = copy.deepcopy(groups[key])
        return expanded

    def records(self, kind: str, *, target: Mapping[str, Any] | None = None) -> list[dict[str, Any]]:
        """Read only current outcomes, preserving each original result identity."""
        self._refresh()
        return [self._expand(entry["record"], self.value["inputGroups"])
                for entry in self.value["entries"].values()
                if entry["kind"] == kind and (target is None or entry["target"] == target)]

    def put(self, kind: str, check_id: str, target: dict[str, Any], record: Mapping[str, Any]) -> None:
        """Replace only this check after its actual outcome is known."""
        self.put_many([(kind, check_id, target, record)])

    def put_many(self, outcomes: list[tuple[str, str, dict[str, Any], Mapping[str, Any]]]) -> None:
        """Save an explicit import together; ordinary tests still save individually."""
        self._refresh()
        groups = dict(self.value["inputGroups"])
        entries = dict(self.value["entries"])
        for kind, check_id, target, record in outcomes:
            encoded = copy.deepcopy(dict(record))
            inputs = encoded.pop("inputs", None)
            if inputs is not None:
                inputs = dict(inputs)
                checks = inputs.pop("check_inputs", None)
                for field, facts in (("inputGroup", inputs), ("checkGroup", checks)):
                    if facts is not None:
                        key = hashlib.sha256(canonical(facts)).hexdigest()
                        groups[key] = facts
                        encoded[field] = key
            entries[self._key(kind, check_id, target)] = {
                "kind": kind, "check_id": check_id, "target": dict(target), "record": encoded,
            }
        self._save(entries, groups)

    def remove_deleted(self, kind: str, deleted_ids: set[str], target: dict[str, Any]) -> None:
        """Remove explicitly deleted checks, never merely unselected checks."""
        self._refresh()
        entries = {key: entry for key, entry in self.value["entries"].items()
                   if not (entry["kind"] == kind and entry["target"] == target
                           and entry["check_id"] in deleted_ids)}
        if entries != self.value["entries"]:
            self._save(entries, self.value["inputGroups"])

    def _save(self, entries: dict[str, Any], groups: Mapping[str, Any]) -> None:
        used = {entry["record"][name] for entry in entries.values()
                for name in ("inputGroup", "checkGroup") if name in entry["record"]}
        value = {"schema": CURRENT_RESULTS_SCHEMA, "worktree": self.worktree,
                 "entries": entries, "inputGroups": {key: groups[key] for key in sorted(used)}}
        if value == self.value:
            return
        raw = canonical(value)
        if len(raw) > 64 * 1024 * 1024:
            raise ValueError(f"Current check results exceed 64 MiB: {self.path}")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        try:
            with self.pending.open("wb") as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(self.pending, self.path)
        finally:
            self.pending.unlink(missing_ok=True)
        info = self.path.stat()
        self.value = value
        self._stamp = (info.st_mtime_ns, info.st_size, info.st_ino)


def _execution_fields(value: Any, *, completed: bool) -> bool:
    if not isinstance(value, dict) or set(value) != {
        "startedAt", "finishedAt", "durationSeconds", "workerPid",
    }:
        return False
    if type(value["workerPid"]) is not int or value["workerPid"] <= 0:
        return False
    try:
        start = datetime.datetime.fromisoformat(value["startedAt"])
        if start.utcoffset() != datetime.timedelta(0):
            return False
        if completed:
            finish = datetime.datetime.fromisoformat(value["finishedAt"])
            return (finish.utcoffset() == datetime.timedelta(0) and finish >= start
                    and type(value["durationSeconds"]) in (int, float)
                    and value["durationSeconds"] >= 0)
        return value["finishedAt"] is None and value["durationSeconds"] is None
    except (TypeError, ValueError):
        return False


def prepare_result(
    path: pathlib.Path, expected: dict[str, Any], *, repair_unaccepted: bool,
    execution: dict[str, Any] | None = None,
) -> bool:
    """Reuse exact acceptance or claim a new attempt without replacing history."""
    exists, saved = read_result(path)
    if saved is not None:
        allowed = set(expected) | {"status", "exit_code"}
        if "inputs" in expected:
            allowed.add("execution")
        if isinstance(saved, dict) and "checks" in saved:
            allowed.add("checks")
        if isinstance(saved, dict) and "check_summary" in saved:
            allowed.add("check_summary")
        if (isinstance(saved, dict) and set(saved) == allowed
                and all(saved.get(key) == value for key, value in expected.items())
                and saved.get("status") == "passed"
                and type(saved.get("exit_code")) is int and saved["exit_code"] == 0
                and ("inputs" not in expected or _execution_fields(saved.get("execution"), completed=True))
                and ("checks" not in saved or (isinstance(saved["checks"], list)
                     and all(isinstance(item, dict) and item.get("status") not in {
                         "failed", "blocked", "interrupted",
                     } for item in saved["checks"])))
                and path.read_bytes() == canonical(saved)):
            return True
        if isinstance(saved, dict) and all(saved.get(key) == value for key, value in expected.items()):
            raise ValueError("saved result is not acceptance; use a new result ID and path")
        raise ValueError("result identity or content conflicts with the request")
    if exists and not repair_unaccepted:
        raise ValueError("malformed result requires caller confirmation that it was never accepted: --repair-unaccepted-result")
    running = {**expected, "status": "running", "exit_code": None}
    if execution is not None:
        running["execution"] = execution
    write_result(path, running, exclusive=not exists)
    return False


def add_result_arguments(parser: argparse.ArgumentParser) -> None:
    """Expose completed 1e.3's caller-owned identity and final-path interface."""
    parser.add_argument("--result-file", type=pathlib.Path, help="Operation-owned final JSON file.")
    for field in IDENTITY_FIELDS:
        parser.add_argument("--" + field.replace("_", "-"))
    parser.add_argument("--describe-test-results", action="store_true", help="Print the supported result contract.")
    parser.add_argument("--repair-unaccepted-result", action="store_true", help="Caller confirms a malformed owned result was never accepted.")
    parser.add_argument("--probe-command", help="JSON argv for a controlled compatibility probe; uses the actual result writer.")


def describe_result_contract() -> None:
    print(json.dumps({"schema": CONTRACT_SCHEMA, "result_schema": CHECK_RESULT_SCHEMA}, sort_keys=True))


def check_result_context(check_version: str) -> dict[str, Any] | None:
    """Read authoritative scheduling inputs; absent historical scope stays absent."""
    raw = os.environ.get(CHECK_CONTEXT_ENV)
    if raw is None:
        return None
    context = json.loads(raw, object_pairs_hook=_object, parse_constant=_nonfinite)
    fields = {
        "schema", "group", "scope", "qualificationLevel", "workVersion", "checkVersion",
        "productInputs", "checkInputs", "arguments", "dependencies", "environment", "fingerprint",
    }
    if (not isinstance(context, dict) or set(context) != fields
            or context["schema"] != CHECK_CONTEXT_SCHEMA
            or not isinstance(context["qualificationLevel"], str)
            or context["qualificationLevel"] not in {"alpha", "beta", "rc", "final"}
            or context["checkVersion"] != check_version
            or not all(isinstance(context[key], str) and context[key].strip()
                       for key in ("group", "workVersion", "checkVersion"))
            or not isinstance(context["scope"], dict)
            or not all(isinstance(context[key], dict)
                       for key in ("productInputs", "checkInputs", "dependencies", "environment"))
            or not isinstance(context["arguments"], list)
            or not all(isinstance(item, str) for item in context["arguments"])
            or not isinstance(context["fingerprint"], str)
            or re.fullmatch(r"[0-9a-f]{64}", context["fingerprint"]) is None):
        raise ValueError("repository check context is incomplete or conflicts with the requested check version")
    canonical(context)
    return context


def _check_file_digest(root: pathlib.Path, name: str) -> str | None:
    path = root / name
    if not path.resolve().is_relative_to(root):
        raise ValueError("repository check input escapes the checkout")
    if not path.exists():
        return None
    if path.is_symlink() or path.is_junction() or not path.is_file():
        raise ValueError("repository check input must be a regular owned file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def _check_inventory(root: pathlib.Path, patterns: list[str], files: list[str]) -> dict[str, Any]:
    def matches(name: str, pattern: str) -> bool:
        return fnmatch.fnmatchcase(name, pattern) or (
            pattern.startswith("**/") and fnmatch.fnmatchcase(name, pattern[3:]))
    names = {name for name in files if any(matches(name, rule) for rule in patterns)}
    names.update(rule for rule in patterns if not any(char in rule for char in "*?["))
    return {name: _check_file_digest(root, name) for name in sorted(names)}


def _check_environment_value(value: str | None, root: pathlib.Path) -> str | None:
    """Keep owned checkout relocation out of declared environment identities."""
    if value is None:
        return None
    resolved = str(root.resolve())
    prefixes = sorted({resolved, resolved.replace("\\", "/"), resolved.replace("/", "\\")},
                      key=len, reverse=True)
    pattern = "(?:" + "|".join(re.escape(prefix) for prefix in prefixes) + r")(?=[\\/;:]|$)"
    flags = re.IGNORECASE if os.name == "nt" else 0
    return re.sub(pattern, lambda _match: "${REPO_ROOT}", value, flags=flags)


def _check_environment_file(value: str | None, root: pathlib.Path) -> str | None:
    """Bind the explicitly declared event-file pointer to its current bytes."""
    if not value:
        return None
    path = pathlib.Path(value)
    path = path if path.is_absolute() else root / path
    if not path.exists():
        return None
    path = path.resolve(strict=True)
    if not path.is_file():
        raise ValueError("declared environment file must be a regular file")
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check_current_inputs(context: Mapping[str, Any], root: pathlib.Path) -> None:
    """Reject edits, new/deleted owned files and execution-scope drift.

    These are integrity/input comparisons, never a second execution of accepted
    checks. Both boundaries use the existing operation declaration, not another
    dependency graph. A check that changes its own declared inputs cannot pass.
    """
    for files in context["scope"].get("artifacts", {}).values():
        for item in files:
            artifact_path = pathlib.Path(item["path"])
            if not artifact_path.is_file() or hashlib.sha256(artifact_path.read_bytes()).hexdigest() != item["sha256"]:
                raise ValueError("Selected built artifact changed before check completion: " + str(artifact_path))
    rules = context["scope"].get("inputRules")
    if (not isinstance(rules, dict)
            or not all(isinstance(rules.get(key), list) and rules[key]
                       and all(isinstance(item, str) and item for item in rules[key])
                       for key in ("product-inputs", "check-inputs"))):
        raise ValueError("repository check input ownership is incomplete")
    result = subprocess.run(
        ["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
        cwd=root, capture_output=True, text=True, check=False,
    )
    if result.returncode:
        raise ValueError("cannot inspect repository check input inventory")
    files = sorted(set(result.stdout.split("\0")) - {""})
    for field, key in (("productInputs", "product-inputs"), ("checkInputs", "check-inputs")):
        if _check_inventory(root, rules[key], files) != context[field]:
            raise ValueError("repository check " + field + " changed before completion")
    dependencies = {name: _check_file_digest(root, name) for name in rules.get("dependencies", [])}
    if dependencies != context["dependencies"] or any(value is None for value in dependencies.values()):
        raise ValueError("repository check dependencies changed before completion")
    recorded = context["environment"]
    variables = {
        name: hashlib.sha256(canonical(_check_environment_value(os.environ.get(name), root))).hexdigest()
        for name in rules.get("environment", [])
    }
    if (recorded.get("variables") != variables or recorded.get("platform") != platform.system()
            or recorded.get("architecture") != platform.machine()):
        raise ValueError("repository check environment changed before completion")
    if "files" in recorded:
        environment_files = {
            name: _check_environment_file(os.environ.get(name), root)
            for name in rules.get("environment", []) if name == "GITHUB_EVENT_PATH"
        }
        if environment_files != recorded["files"]:
            raise ValueError("repository check environment file changed before completion")
    tools: dict[str, dict[str, str | None]] = {}
    for name in rules.get("tools", []):
        expanded = re.sub(r"\$\{([^}]+)\}", lambda match: os.environ.get(match[1], ""), name)
        path: pathlib.Path | None
        if "/" in expanded or "\\" in expanded:
            path = pathlib.Path(expanded)
            path = path if path.is_absolute() else root / path
        else:
            found = shutil.which(expanded)
            path = pathlib.Path(found) if found else None
        if path is not None and not path.exists():
            path = None
        if path is not None:
            path = path.resolve(strict=True)
        if path is not None and (path.is_symlink() or path.is_junction() or not path.is_file()):
            raise ValueError("repository check tool must be a regular file")
        tools[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest() if path is not None else None}
    if recorded.get("tools") != tools:
        raise ValueError("repository check tools changed before completion")
    if recorded.get("runtime"):
        runtime = {
            "python": platform.python_version(), "implementation": platform.python_implementation(),
            "packages": sorted(
                [dist.metadata["Name"].lower(), dist.version]
                for dist in importlib.metadata.distributions()
            ),
        }
        if runtime != recorded["runtime"]:
            raise ValueError("repository check locked runtime differs from the selected runtime")



def parse_check_summary(raw: bytes) -> dict[str, Any]:
    """Read self-contained check facts; missing historical facts grant no reuse."""
    if len(raw) > 16 * 1024 * 1024:
        raise ValueError("Check summary exceeds the size limit.")
    value = json.loads(raw)
    if (not isinstance(value, dict)
            or set(value) != {"schema", "inputGroups", "checkGroups", "checks"}
            or value["schema"] != "ceratops-check-summary.v1"
            or not isinstance(value["checks"], list)):
        raise ValueError("Check summary has incomplete fields.")
    for name in ("inputGroups", "checkGroups"):
        table = value[name]
        if not isinstance(table, dict):
            raise ValueError("Check summary input table is missing.")
        for identity, facts in table.items():
            digest = hashlib.sha256(json.dumps(facts, sort_keys=True, ensure_ascii=True,
                                               separators=(",", ":"), allow_nan=False).encode()).hexdigest()
            if identity != digest or not isinstance(facts, dict):
                raise ValueError("Check summary input hash differs from its facts.")
    identities = set()
    for check in value["checks"]:
        if (not isinstance(check, dict) or not isinstance(check.get("id"), str)
                or not isinstance(check.get("status"), str)
                or ("required" in check and type(check["required"]) is not bool)):
            raise ValueError("Check summary outcome is incomplete.")
        identity = (check.get("kind"), check["id"])
        if identity in identities:
            raise ValueError("Check summary repeats one check.")
        identities.add(identity)
        for field, table in (("inputGroup", "inputGroups"), ("checkGroup", "checkGroups"),
                             ("applicableInputGroup", "inputGroups"), ("comparisonInputGroup", "inputGroups")):
            if field in check and check[field] not in value[table]:
                raise ValueError("Check summary names an absent input group.")
    return value


def build_qualification(version: str) -> str:
    """Use the existing PEP 440 version format, not tag-name substring guesses."""
    from packaging.version import Version

    parsed = Version(version)
    if parsed.dev is not None:
        return "alpha"
    return {"a": "alpha", "b": "beta", "rc": "rc"}[parsed.pre[0]] if parsed.pre else "final"


def _build_git(root: pathlib.Path, *arguments: str, missing: bool = False) -> bytes:
    command = ["git", "-C", str(root), *arguments]
    try:
        result = subprocess.run(command, cwd=root, capture_output=True, check=False)
    except OSError as exc:
        result = None
        cause = str(exc)
    else:
        assert result is not None
        if result.returncode == 0:
            return result.stdout
        if missing and result.returncode == 1:
            return b""
        cause = "Git could not read the selected build."
    details = json.dumps({
        "operation": "read-build-history", "target": str(root), "command": command,
        "python_runtime": sys.executable, "cwd": str(root),
        "exit_status": result.returncode if result is not None else None,
        "cause": cause,
        "stdout": (result.stdout.decode("utf-8", "replace") or "<empty>") if result is not None else "<unavailable: launch failed>",
        "stderr": (result.stderr.decode("utf-8", "replace") or "<empty>") if result is not None else "<unavailable: launch failed>",
    })
    for name, value in os.environ.items():
        if len(value) >= 4 and any(word in name.upper() for word in ("TOKEN", "PASSWORD", "SECRET", "API_KEY")):
            details = details.replace(value, "<redacted>")
    raise ValueError(details)


def _build_blob(root: pathlib.Path, commit: str, path: str, limit: int) -> bytes:
    """Only literal regular Git files can supply committed reuse facts."""
    if ("\\" in path or path.startswith("/") or ":" in path
            or any(part in {"", ".", ".."} for part in path.split("/"))):
        raise ValueError("Build record path must be repository-relative.")
    entry = _build_git(root, "ls-tree", "-z", commit, "--", f":(literal){path}")
    metadata, separator, actual = entry.rstrip(b"\0").partition(b"\t")
    fields = metadata.split()
    if (not separator or actual != path.encode() or len(fields) != 3
            or fields[0] not in {b"100644", b"100755"} or fields[1] != b"blob"):
        raise ValueError("Build history requires a regular committed file: " + path)
    oid = fields[2].decode("ascii")
    if int(_build_git(root, "cat-file", "-s", oid)) > limit:
        raise ValueError("Committed build record exceeds its size limit.")
    return _build_git(root, "cat-file", "blob", oid)


def read_build_check_summary(root: pathlib.Path, tag: str, receipt_path: str) -> dict[str, Any]:
    """Read only the tagged receipt and summary; never open packages or full logs."""
    _build_git(root, "check-ref-format", "refs/tags/" + tag)
    commit = _build_git(root, "rev-parse", "--verify", "--end-of-options",
                        f"refs/tags/{tag}^{{commit}}").decode().strip()
    raw = _build_blob(root, commit, receipt_path, 1024 * 1024)
    receipt = json.loads(raw)
    identity = receipt["identity"]
    expected_tag = identity["releaseUnit"] + "/" + identity["version"]
    parent = f'.build/{identity["releaseUnit"]}/{identity["version"]}'
    expected_paths = {parent + "/build_receipt.json",
                      parent + "/" + identity["target"] + "/build_receipt.json"}
    if (receipt.get("schema") != "ceratops-build-result.v3" or receipt.get("status") != "passed"
            or receipt.get("receiptPath") != receipt_path or receipt_path not in expected_paths
            or tag != expected_tag or receipt.get("tag", tag) != tag):
        raise ValueError("Build tag, identity and committed receipt path disagree.")
    summary = {"schema": "ceratops-check-summary.v1", "inputGroups": {}, "checkGroups": {}, "checks": []}
    reference = receipt.get("checkSummary")
    if reference is not None:
        expected = str(pathlib.PurePosixPath(receipt_path).with_name("check_summary.json"))
        if (receipt.get("tag") != tag or reference.get("root") != "git"
                or reference.get("path") != expected
                or expected not in receipt["committedResultPaths"]):
            raise ValueError("Build receipt has an invalid check-summary link.")
        content = _build_blob(root, commit, expected, 16 * 1024 * 1024)
        if len(content) != reference["size"] or hashlib.sha256(content).hexdigest() != reference["sha256"]:
            raise ValueError("Committed check summary differs from its receipt.")
        summary = parse_check_summary(content)
    return {"tag": tag, "commit": commit, "receiptPath": receipt_path,
            "receipt": receipt, "summary": summary}


def select_build_check_summaries(
    root: pathlib.Path, *, qualification_level: str = "alpha",
    unit: str | None = None, target: str | None = None,
) -> list[dict[str, Any]]:
    """Choose the newest eligible version in this checkout's .build records.

    Git tags prove completion; the checkout supplies only selection identities.
    No ancestry walk, other checkout, deployment history or artifact-store scan.
    A newer completed historical build with no summary supplies no coverage,
    instead of silently borrowing an older build.
    """
    from packaging.version import InvalidVersion, Version

    levels = ("alpha", "beta", "rc", "final")
    if qualification_level not in levels:
        raise ValueError("Unsupported build qualification level.")
    history = root / ".build"
    if not history.is_dir():
        return []
    candidates: list[tuple[Any, str, str, pathlib.Path, str]] = []
    for pattern in ("*/*/build_receipt.json", "*/*/*/build_receipt.json"):
        for path in history.glob(pattern):
            if any(parent.is_symlink() or parent.is_junction() for parent in (path, *path.parents)):
                raise ValueError("Build history cannot traverse directory links.")
            if path.stat().st_size > 1024 * 1024:
                raise ValueError("Local build receipt exceeds its size limit.")
            try:
                receipt = json.loads(path.read_bytes())
                identity = receipt["identity"]
                name, destination, version = identity["releaseUnit"], identity["target"], identity["version"]
                level = build_qualification(version)
                if (unit is not None and name != unit) or (target is not None and destination != target):
                    continue
                if levels.index(level) < levels.index(qualification_level):
                    continue
                tag = name + "/" + version
                if receipt.get("status") != "passed" or receipt.get("tag", tag) != tag:
                    continue
                candidates.append((Version(version), name, destination, path, tag))
            except (ValueError, KeyError, TypeError, InvalidVersion):
                continue  # Interrupted local preparation is not a completed build.
    chosen: dict[tuple[str, str], dict[str, Any]] = {}
    for _version, name, destination, path, tag in sorted(candidates, key=lambda row: (row[0], str(row[3])), reverse=True):
        if (name, destination) in chosen:
            continue
        # An absent tag is an unfinished preparation, not an accepted baseline.
        if not _build_git(root, "rev-parse", "--verify", "--quiet", "--end-of-options",
                          "refs/tags/" + tag, missing=True):
            continue
        selected = read_build_check_summary(root, tag, path.relative_to(root).as_posix())
        identity = selected["receipt"]["identity"]
        if (identity["releaseUnit"], identity["target"]) != (name, destination):
            raise ValueError("Local build selector differs from the tagged identity.")
        chosen[(name, destination)] = selected
    return [chosen[key] for key in sorted(chosen)]


def summarize_check_result(record: Mapping[str, Any], children: Any = None) -> dict[str, Any]:
    """Export compact original outcomes with all applicability facts inlined.

    Tables deduplicate group and test-file inputs. No receipt, log or package
    must survive elsewhere for these facts to remain usable. Absent historical
    inputs stay absent; this exporter never invents an executed check.
    """
    result: dict[str, Any] = {"schema": "ceratops-check-summary.v1", "inputGroups": {},
              "checkGroups": {}, "checks": []}
    if children:
        if not isinstance(children, dict) or children.get("schema") != result["schema"]:
            raise ValueError("unsupported compact check summary")
        result["inputGroups"].update(children["inputGroups"])
        result["checkGroups"].update(children["checkGroups"])
        for item in children["checks"]:
            outcome = dict(item)
            # Embedded input facts make the summary independent of mutable local
            # result files. Their links remain in the original observation only.
            if (outcome.get("kind") == "pytest"
                    and outcome.get("inputGroup") in result["inputGroups"]
                    and outcome.get("checkGroup") in result["checkGroups"]):
                outcome.pop("path", None)
                outcome.pop("sha256", None)
            result["checks"].append(outcome)
    represented = {item["id"] for item in result["checks"]}
    result["checks"].extend({**item, **({"required": False} if item.get("status") in {"skipped", "scope-unrepresented"} else {})}
                            for item in record.get("checks", [])
                            if item.get("id") not in represented)
    if isinstance(record.get("inputs"), dict) and record.get("execution", {}).get("finishedAt"):
        context = record["inputs"]
        group = hashlib.sha256(canonical(context).rstrip(b"\n")).hexdigest()
        result["inputGroups"][group] = context
        finished = datetime.datetime.fromisoformat(record["execution"]["finishedAt"])
        result["checks"].append({
            "kind": "repository-check", "id": record["check_id"], "status": record["status"], "required": True,
            "result_id": record["result_id"], "check_version": record["check_version"],
            "candidate_id": record["candidate_id"], "qualificationLevel": context["qualificationLevel"],
            "completed_ns": int(finished.timestamp() * 1_000_000_000),
            "inputGroup": group, "inputs_digest": context["fingerprint"],
            "reusable": not any(item.get("reusable") is False for item in record.get("checks", [])),
            "children": [{"kind": item.get("kind"), "id": item["id"]} for item in result["checks"]],
        })
    return result


def run_recorded_check(
    callback: Callable[[], int], args: argparse.Namespace, invocation: Mapping[str, Any],
    *, checks: Callable[[], Any] | None = None, repo_root: pathlib.Path | None = None,
    summary: Callable[[], Any] | None = None,
) -> int:
    """Write actual runner outcomes before success and preserve original attempts.

    The shared operation owner allocates identity, inputs, path and retention;
    this producer never invents acceptance from Git metadata or another runner.
    Without result arguments the existing disposable invocation is preserved.
    """
    supplied = [getattr(args, "result_file", None) is not None,
                *(getattr(args, field, None) is not None for field in IDENTITY_FIELDS)]
    if not any(supplied):
        if getattr(args, "repair_unaccepted_result", False) or getattr(args, "probe_command", None):
            print("repair-unaccepted-result and probe-command require result arguments", file=sys.stderr)
            return 2
        return callback()
    path: pathlib.Path | None = None
    try:
        if not all(supplied):
            raise ValueError("result-file, result-id, candidate-id, check-id and check-version must be supplied together")
        if any(not getattr(args, field).strip() for field in IDENTITY_FIELDS):
            raise ValueError("result identities must not be empty")
        context = check_result_context(args.check_version)
        expected = {
            "schema": CHECK_RESULT_SCHEMA,
            **{field: getattr(args, field) for field in IDENTITY_FIELDS},
            "invocation": dict(invocation),
        }
        started = datetime.datetime.now(datetime.UTC)
        monotonic_start = time.monotonic()
        execution = {
            "startedAt": started.isoformat(), "finishedAt": None,
            "durationSeconds": None, "workerPid": os.getpid(),
        } if context is not None else None
        if context is not None:
            expected["inputs"] = context
        root = (repo_root or pathlib.Path.cwd()).resolve()
        if context is not None:
            check_current_inputs(context, root)
        path = result_path(args.result_file)
        prepare: dict[str, Any] = {"repair_unaccepted": getattr(args, "repair_unaccepted_result", False)}
        if execution is not None:
            prepare["execution"] = execution
        current = CurrentCheckResults(root) if context is not None else None
        if current is not None and path != current.path:
            current = None  # Explicit caller-selected output keeps the public probe contract.
        target = {key: value for key, value in context["scope"].items()
                  if key not in {"worktree", "inputRules", "artifacts"}} if current is not None and context is not None else {}
        saved = next((item for item in current.records("repository-check", target=target)
                      if item["result_id"] == args.result_id), None) if current is not None else None
        if saved is not None:
            if (not all(saved.get(key) == value for key, value in expected.items())
                    or saved.get("status") != "passed" or saved.get("exit_code") != 0):
                raise ValueError("Saved result ID does not identify this successful check.")
            print("OK")
            return 0
        if current is None and prepare_result(path, expected, **prepare):
            print("OK")
            return 0
        running = {**expected, "status": "running", "exit_code": None}
        if execution is not None:
            running["execution"] = execution
        failure: BaseException | None = None
        try:
            if context is not None:
                check_current_inputs(context, root)
            code = callback()
            if context is not None:
                check_current_inputs(context, root)
            if type(code) is not int:
                raise ValueError("check callback must return an integer exit code")
            code = code if code >= 0 else 1
            status = "passed" if code == 0 else "failed"
        except KeyboardInterrupt:
            code, status = 130, "interrupted"
        except SystemExit as exc:
            code = exc.code if type(exc.code) is int else (0 if exc.code is None else 1)
            code = code if code >= 0 else 1
            status = "passed" if code == 0 else "failed"
        except BaseException as exc:
            code, status, failure = 1, "failed", exc
        completed = {**expected, "status": status, "exit_code": code}
        if execution is not None:
            completed["execution"] = {
                **execution, "finishedAt": datetime.datetime.now(datetime.UTC).isoformat(),
                "durationSeconds": max(0.0, time.monotonic() - monotonic_start),
            }
        if checks is not None:
            completed["checks"] = checks()
        if context is not None or summary is not None:
            completed["check_summary"] = summarize_check_result(completed, summary() if summary else None)
        if current is not None:
            current.put("repository-check", args.check_id, target, completed)
        else:
            if read_result(path)[1] != running:
                raise ValueError("running result changed; refusing to overwrite it")
            write_result(path, completed, exclusive=False)
        if failure is not None:
            raise failure
        return code
    except (OSError, ValueError) as exc:
        print(str(exc), file=sys.stderr)
        return 2


def main() -> int:
    """Emit structured package-build or idempotent Android-deployment results."""

    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build-result")
    build_parser.add_argument("--artifact", type=pathlib.Path, required=True)
    build_parser.add_argument("--type", required=True)
    deploy_parser = subparsers.add_parser("android-deploy")
    deploy_parser.add_argument("--adb-executable", required=True)
    deploy_parser.add_argument("--device", required=True)
    deploy_parser.add_argument("--package", required=True)
    deploy_parser.add_argument("--activity", required=True)
    deploy_parser.add_argument("--artifact", type=pathlib.Path, required=True)
    deploy_parser.add_argument("--type", required=True)
    args = parser.parse_args()
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    try:
        if args.command == "build-result":
            result = build_result(repo_root, args.artifact, args.type)
        else:
            result = android_deploy_result(
                repo_root,
                adb_executable=args.adb_executable,
                device=args.device,
                package=args.package,
                activity=args.activity,
                artifact=args.artifact,
                artifact_type=args.type,
            )
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
