#!/usr/bin/env python3
"""Own bounded AstroTops validation, test, and build records.

Repository validation and test runners share this only writer of portable
``.test-results`` JSON. It binds every result to the current source bytes and
commit, writes through an atomic sibling file, and retains at most three
ignored evidence runs. Candidate build records additionally require an exact
immutable source tag and hash the artifact stored under ``.build/artifacts``;
the tag is the build version while the commit remains traceability metadata.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import subprocess
import sys
import tempfile
from collections.abc import Callable
from dataclasses import dataclass
from typing import Iterable

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
    listing = _git(repo_root, "ls-files", "-z").stdout.split("\0")
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

    def begin_evidence_run(self, run_id: str) -> pathlib.Path:
        """Create the current ignored evidence directory and retain three runs."""

        run_root = self.evidence_root / run_id
        run_root.mkdir(parents=True, exist_ok=True)
        self.prune_evidence(keep={run_id})
        return run_root

    def prune_evidence(self, *, keep: set[str] | None = None) -> None:
        """Retain the current evidence run and at most two predecessors."""

        if not self.evidence_root.is_dir():
            return
        keep = set(keep or ())
        directories = sorted(
            (path for path in self.evidence_root.iterdir() if path.is_dir()),
            key=lambda path: (path.stat().st_mtime_ns, path.name),
            reverse=True,
        )
        retained = set(keep)
        for path in directories:
            if path.name in retained:
                continue
            if len(retained) < 3:
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

    connect = run([adb_executable, "connect", device])
    connect_output = _require_command(connect, "connect Android device")
    if not any(
        marker in connect_output.lower()
        for marker in ("connected to", "already connected to")
    ):
        raise ValueError(f"ADB did not establish the requested connection: {connect_output[:512]}")

    expected_hash = str(descriptor["sha256"])
    installed_hash = _installed_apk_hash(
        adb_executable, device, package, run
    )
    if installed_hash != expected_hash:
        install = run(
            [
                adb_executable,
                "-s",
                device,
                "install",
                "-r",
                str(artifact.expanduser().resolve(strict=True)),
            ]
        )
        install_output = _require_command(install, "install Android package")
        if not any(line.strip() == "Success" for line in install_output.splitlines()):
            raise ValueError(f"ADB did not confirm installation: {install_output[:512]}")
        installed_hash = _installed_apk_hash(
            adb_executable, device, package, run
        )
    if installed_hash != expected_hash:
        raise ValueError(
            f"installed APK hash mismatch: expected={expected_hash} actual={installed_hash}"
        )

    launch = run(
        [
            adb_executable,
            "-s",
            device,
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
        "target": device,
        "artifact": descriptor,
    }


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
