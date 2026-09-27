#!/usr/bin/env python3
"""Provision Godot and run AstroTops validation, export, and regressions.

The helper owns the pinned Godot tool cache used by repository lifecycle steps.
The feature inventory owns group coverage and source-file ownership. Each test
group runs in an isolated temporary directory; rendered tests use a real Godot
OpenGL window (under Xvfb on Linux). The runner atomically updates the affected
group, preserves only still-applicable passing groups, recalculates the overall
result, and leaves compact assertion differences in both the console and
bounded ``.test-results/evidence`` logs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import platform
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import urllib.request
import zipfile
from collections.abc import Callable, Mapping
from datetime import UTC, datetime

_SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from result_records import (  # noqa: E402
    GROUP_SCHEMA,
    RESULT_SCHEMA,
    VALIDATION_SCHEMA,
    ArtifactIdentity,
    ResultStore,
    SourceIdentity,
    android_deploy_result,
    group_fingerprint,
    resolve_artifact_identity,
    resolve_source_identity,
)

INVENTORY_SCHEMA = "astrotops-test-inventory.v1"
GODOT_RESULT_PREFIX = "ASTROTOPS_TEST_RESULT="
GODOT_VERSION = "4.7.2"
GODOT_CACHE_SCHEMA = "astrotops-godot-cache.v1"
GODOT_CACHE_PREDECESSORS = 2
GODOT_CACHE_LOCK_STALE_SECONDS = 900.0
GODOT_CACHE_LOCK_WAIT_SECONDS = 120.0
GODOT_ARCHIVES: dict[tuple[str, str], dict[str, object]] = {
    ("windows", "x86_64"): {
        "url": "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_win64.exe.zip",
        "sha256": "731980f9608d61333e5baf54a2ef17210acc7a538446c0cb9969f002aca1e953",
        "size": 86_013_866,
        "members": [
            "Godot_v4.7.2-stable_win64.exe",
            "Godot_v4.7.2-stable_win64_console.exe",
        ],
        "executable": "Godot_v4.7.2-stable_win64_console.exe",
    },
    ("linux", "x86_64"): {
        "url": "https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip",
        "sha256": "cadd3204e728a35d3f13adb7fd0d7902636b79f6b95c40c265eb73b6c35329e4",
        "size": 77_860_424,
        "members": ["Godot_v4.7.2-stable_linux.x86_64"],
        "executable": "Godot_v4.7.2-stable_linux.x86_64",
    },
}


def load_inventory(repo_root: pathlib.Path) -> tuple[dict[str, object], list[dict[str, object]]]:
    """Load the feature map and reject missing groups or unowned test inputs."""

    path = repo_root / "docs" / "feature-acceptance.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    inventory = document.get("testInventory")
    if not isinstance(inventory, dict) or inventory.get("schema") != INVENTORY_SCHEMA:
        raise ValueError("docs/feature-acceptance.json has no supported test inventory.")
    groups = inventory.get("groups")
    owners = inventory.get("fileOwners")
    requirements = document.get("requirements")
    if not isinstance(groups, list) or not groups:
        raise ValueError("The test inventory must declare groups.")
    if not isinstance(owners, dict) or not owners:
        raise ValueError("The test inventory must map source files to groups.")
    if not isinstance(requirements, list) or not requirements:
        raise ValueError("The feature map must declare acceptance requirements.")
    validated_groups: list[dict[str, object]] = []
    group_ids: list[str] = []
    for item in groups:
        if not isinstance(item, dict) or not isinstance(item.get("id"), str):
            raise ValueError("Every test group needs one unique string id.")
        validated_groups.append(item)
        group_ids.append(item["id"])
    if len(set(group_ids)) != len(group_ids):
        raise ValueError("Every test group needs one unique id.")
    for item in validated_groups:
        if item.get("mode") not in ("headless", "rendered", "python"):
            raise ValueError(f"Test group {item.get('id')!r} has an unsupported mode.")
    declared = set(group_ids)
    for relative, selected in owners.items():
        if not isinstance(relative, str) or not (repo_root / relative).is_file():
            raise ValueError(f"Inventoried source file is missing: {relative}")
        if not isinstance(selected, list) or not selected or not set(selected) <= declared:
            raise ValueError(f"Inventoried source file has invalid group owners: {relative}")
    covered: set[str] = set()
    for requirement in requirements:
        if not isinstance(requirement, dict) or not requirement.get("id"):
            raise ValueError("Every feature requirement needs an id.")
        selected = requirement.get("groups")
        observations = requirement.get("observations")
        if not isinstance(selected, list) or not selected or not set(selected) <= declared:
            raise ValueError(f"Requirement {requirement.get('id')} has invalid groups.")
        if not isinstance(observations, list) or not observations:
            raise ValueError(f"Requirement {requirement.get('id')} has no observable tests.")
        covered.update(selected)
    if covered != declared:
        raise ValueError(f"Feature coverage omits groups: {sorted(declared - covered)}")
    return inventory, validated_groups


def godot_version(executable: pathlib.Path) -> str:
    completed = subprocess.run(
        [str(executable), "--version"],
        check=False,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        timeout=30,
    )
    if completed.returncode:
        raise RuntimeError("Godot version probe failed: " + completed.stderr.strip())
    return completed.stdout.strip().splitlines()[0]


def _require_godot_version(
    executable: pathlib.Path,
    *,
    version_probe: Callable[[pathlib.Path], str] = godot_version,
) -> str:
    """Reject a runtime that is present but not the repository's pinned version."""

    version = version_probe(executable)
    if not version.startswith(GODOT_VERSION + "."):
        raise RuntimeError(
            f"Godot {GODOT_VERSION} is required; {executable} reports {version!r}."
        )
    return version


def godot_cache_root(environ: Mapping[str, str] | None = None) -> pathlib.Path:
    """Return the user-cache owner for versioned AstroTops Godot runtimes."""

    values = os.environ if environ is None else environ
    override = values.get("ASTROTOPS_TOOL_CACHE")
    if override:
        return pathlib.Path(override).expanduser().resolve() / "godot"
    if platform.system().lower() == "windows":
        base = pathlib.Path(
            values.get("LOCALAPPDATA", pathlib.Path.home() / "AppData" / "Local")
        )
        return base / "Ceratops" / "AstroTops" / "tools" / "godot"
    base = pathlib.Path(values.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache"))
    return base / "ceratops" / "astrotops" / "tools" / "godot"


def _normalized_architecture(machine: str) -> str:
    value = machine.lower().replace("-", "_")
    if value in {"amd64", "x64", "x86_64"}:
        return "x86_64"
    return value


def godot_archive_spec(
    system_name: str | None = None,
    machine: str | None = None,
) -> dict[str, object]:
    """Select the exact official archive supported for this host."""

    key = (
        (system_name or platform.system()).lower(),
        _normalized_architecture(machine or platform.machine()),
    )
    selected = GODOT_ARCHIVES.get(key)
    if selected is None:
        raise RuntimeError(
            "No pinned Godot archive is declared for "
            f"{key[0]}/{key[1]}; pass --godot or set GODOT_EXECUTABLE."
        )
    return dict(selected)


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _download_godot_archive(url: str, destination: pathlib.Path) -> None:
    """Download one official archive without modifying global installer state."""

    request = urllib.request.Request(url, headers={"User-Agent": "AstroTops-tool-bootstrap/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        with destination.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)


class _GodotCacheLock:
    """Serialize cache mutation and recover only demonstrably stale owners."""

    def __init__(self, root: pathlib.Path) -> None:
        self.path = root / ".provision-lock"
        self.token = f"{os.getpid()}-{time.time_ns()}"

    def __enter__(self) -> None:
        deadline = time.monotonic() + GODOT_CACHE_LOCK_WAIT_SECONDS
        while True:
            try:
                self.path.mkdir()
                (self.path / "owner").write_text(
                    self.token + "\n", encoding="utf-8", newline="\n"
                )
                return
            except FileExistsError as error:
                if not self.path.is_dir() or self.path.is_symlink():
                    raise RuntimeError(
                        f"Godot cache lock has an invalid type: {self.path}"
                    ) from error
                age = time.time() - self.path.stat().st_mtime
                if age > GODOT_CACHE_LOCK_STALE_SECONDS:
                    shutil.rmtree(self.path)
                    continue
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"Timed out waiting for Godot cache lock: {self.path}"
                    ) from error
                time.sleep(0.25)

    def __exit__(self, *_error: object) -> None:
        owner = self.path / "owner"
        try:
            if owner.read_text(encoding="utf-8").strip() == self.token:
                shutil.rmtree(self.path)
        except FileNotFoundError:
            return


def _cleanup_godot_orphans(root: pathlib.Path) -> None:
    """Remove interrupted helper-owned downloads and extraction directories."""

    for child in root.iterdir():
        if not child.name.startswith((".download-", ".extract-")):
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def _prune_godot_cache(root: pathlib.Path, current_version: str) -> None:
    """Retain the current runtime and at most two most-recent predecessors."""

    predecessors = [
        child
        for child in root.iterdir()
        if child.is_dir()
        and not child.is_symlink()
        and not child.name.startswith(".")
        and child.name != current_version
    ]
    predecessors.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    for obsolete in predecessors[GODOT_CACHE_PREDECESSORS:]:
        shutil.rmtree(obsolete)


def _cached_godot(
    version_root: pathlib.Path,
    spec: Mapping[str, object],
    *,
    version_probe: Callable[[pathlib.Path], str] = godot_version,
) -> pathlib.Path | None:
    """Return one complete, untampered cached runtime or no candidate."""

    manifest_path = version_root / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(manifest, dict):
        return None
    expected = {
        "schema": GODOT_CACHE_SCHEMA,
        "version": GODOT_VERSION,
        "archiveSha256": spec["sha256"],
        "archiveSize": spec["size"],
        "source": spec["url"],
        "executable": spec["executable"],
    }
    if any(manifest.get(key) != value for key, value in expected.items()):
        return None
    member_hashes = manifest.get("memberSha256")
    members = spec.get("members")
    if not isinstance(member_hashes, dict) or not isinstance(members, list):
        return None
    for member in members:
        if not isinstance(member, str):
            return None
        path = version_root / pathlib.PurePosixPath(member).name
        if not path.is_file() or member_hashes.get(member) != _sha256(path):
            return None
    executable_name = spec.get("executable")
    if not isinstance(executable_name, str):
        return None
    executable = version_root / executable_name
    try:
        _require_godot_version(executable, version_probe=version_probe)
    except (OSError, RuntimeError, subprocess.SubprocessError):
        return None
    return executable


def _extract_godot_archive(
    archive_path: pathlib.Path,
    destination: pathlib.Path,
    members: list[str],
) -> dict[str, str]:
    """Extract only allowlisted files and return their content hashes."""

    hashes: dict[str, str] = {}
    with zipfile.ZipFile(archive_path) as archive:
        for member in members:
            info = archive.getinfo(member)
            target = destination / pathlib.PurePosixPath(member).name
            with archive.open(info) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            hashes[member] = _sha256(target)
    return hashes


def provision_godot(
    *,
    cache_root: pathlib.Path | None = None,
    spec: Mapping[str, object] | None = None,
    download: Callable[[str, pathlib.Path], None] = _download_godot_archive,
    version_probe: Callable[[pathlib.Path], str] = godot_version,
) -> pathlib.Path:
    """Provision the pinned runtime atomically in the bounded user tool cache."""

    selected = dict(spec or godot_archive_spec())
    root = (cache_root or godot_cache_root()).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    with _GodotCacheLock(root):
        _cleanup_godot_orphans(root)
        version_root = root / GODOT_VERSION
        cached = _cached_godot(version_root, selected, version_probe=version_probe)
        if cached is not None:
            os.utime(version_root)
            _prune_godot_cache(root, GODOT_VERSION)
            return cached
        if version_root.exists():
            if version_root.is_symlink() or not version_root.is_dir():
                raise RuntimeError(f"Godot cache entry has an invalid type: {version_root}")
            shutil.rmtree(version_root)
        archive_path = root / f".download-{os.getpid()}-{time.time_ns()}.zip"
        extraction_root = pathlib.Path(tempfile.mkdtemp(prefix=".extract-", dir=root))
        try:
            url = selected.get("url")
            expected_hash = selected.get("sha256")
            expected_size = selected.get("size")
            raw_members = selected.get("members")
            executable_name = selected.get("executable")
            if (
                not isinstance(url, str)
                or not isinstance(expected_hash, str)
                or not isinstance(expected_size, int)
                or not isinstance(raw_members, list)
                or not all(isinstance(member, str) for member in raw_members)
                or not isinstance(executable_name, str)
            ):
                raise RuntimeError("Pinned Godot archive metadata is invalid.")
            members = [str(member) for member in raw_members]
            download(url, archive_path)
            actual_size = archive_path.stat().st_size
            actual_hash = _sha256(archive_path)
            if actual_size != expected_size or actual_hash != expected_hash:
                raise RuntimeError(
                    "Godot archive integrity check failed: "
                    f"size={actual_size}/{expected_size}, sha256={actual_hash}/{expected_hash}."
                )
            member_hashes = _extract_godot_archive(
                archive_path, extraction_root, members
            )
            executable = extraction_root / executable_name
            if platform.system().lower() != "windows":
                executable.chmod(
                    executable.stat().st_mode
                    | stat.S_IXUSR
                    | stat.S_IXGRP
                    | stat.S_IXOTH
                )
            _require_godot_version(executable, version_probe=version_probe)
            manifest = {
                "schema": GODOT_CACHE_SCHEMA,
                "version": GODOT_VERSION,
                "source": url,
                "archiveSha256": expected_hash,
                "archiveSize": expected_size,
                "memberSha256": member_hashes,
                "executable": executable_name,
            }
            (extraction_root / "manifest.json").write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
                newline="\n",
            )
            os.replace(extraction_root, version_root)
        except (OSError, RuntimeError, zipfile.BadZipFile, KeyError) as error:
            raise RuntimeError(
                f"Automatic Godot {GODOT_VERSION} provisioning failed in {root}: {error}"
            ) from error
        finally:
            archive_path.unlink(missing_ok=True)
            if extraction_root.exists():
                shutil.rmtree(extraction_root)
        cached = _cached_godot(version_root, selected, version_probe=version_probe)
        if cached is None:
            raise RuntimeError("Provisioned Godot cache entry failed final verification.")
        _prune_godot_cache(root, GODOT_VERSION)
        return cached


def resolve_godot(
    requested: pathlib.Path | None,
    *,
    environ: Mapping[str, str] | None = None,
    which: Callable[[str], str | None] = shutil.which,
    provision: Callable[[], pathlib.Path] | None = None,
    version_probe: Callable[[pathlib.Path], str] = godot_version,
) -> pathlib.Path:
    """Resolve an exact caller runtime or self-provision the pinned release."""

    values = os.environ if environ is None else environ
    if requested is not None:
        executable = requested.expanduser().resolve(strict=True)
        _require_godot_version(executable, version_probe=version_probe)
        return executable
    rejected: list[str] = []
    candidates = [values.get("GODOT_EXECUTABLE"), which("godot"), which("godot.exe")]
    seen: set[str] = set()
    for candidate in candidates:
        if not candidate or candidate in seen:
            continue
        seen.add(candidate)
        try:
            executable = pathlib.Path(candidate).expanduser().resolve(strict=True)
            _require_godot_version(executable, version_probe=version_probe)
            return executable
        except (OSError, RuntimeError, subprocess.SubprocessError) as error:
            rejected.append(str(error))
    try:
        executable = (provision or provision_godot)()
        _require_godot_version(executable, version_probe=version_probe)
        return executable
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        detail = "; ".join(rejected + [str(error)])
        raise RuntimeError(
            f"Godot {GODOT_VERSION} could not be resolved. {detail} "
            "Pass --godot or set GODOT_EXECUTABLE to a verified executable."
        ) from error


def bootstrap_godot_imports(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    *,
    run=subprocess.run,
) -> None:
    """Make Godot import project assets before scripts try to load them."""

    command = [str(godot), "--headless", "--path", str(repo_root), "--import"]
    completed = run(
        command,
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        timeout=120,
    )
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError("Godot asset import failed: " + detail[-1200:])


def _run_godot_operation(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    arguments: list[str],
    *,
    timeout: int,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> None:
    """Run one bounded Godot lifecycle command with compact failure evidence."""

    command = [str(godot), *arguments]
    completed = run(
        command,
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
        timeout=timeout,
    )
    if completed.returncode:
        detail = (completed.stderr or completed.stdout).strip()
        raise RuntimeError(
            f"Godot lifecycle command failed ({completed.returncode}): {detail[-2000:]}"
        )


def validate_godot_project(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> None:
    """Parse the project through the pinned editor before shipping side effects."""

    _run_godot_operation(
        repo_root,
        godot,
        ["--headless", "--editor", "--path", str(repo_root), "--quit"],
        timeout=180,
        run=run,
    )


def export_debug_project(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    output: pathlib.Path,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
) -> pathlib.Path:
    """Create one fresh Android debug artifact inside the repository boundary."""

    resolved = (
        output.expanduser().resolve()
        if output.is_absolute()
        else (repo_root / output).resolve()
    )
    try:
        resolved.relative_to(repo_root)
    except ValueError as error:
        raise RuntimeError(f"Godot export must stay inside {repo_root}: {resolved}") from error
    resolved.parent.mkdir(parents=True, exist_ok=True)
    resolved.unlink(missing_ok=True)
    _run_godot_operation(
        repo_root,
        godot,
        [
            "--headless",
            "--path",
            str(repo_root),
            "--export-debug",
            "Android",
            str(resolved),
        ],
        timeout=900,
        run=run,
    )
    if not resolved.is_file() or resolved.stat().st_size <= 0:
        raise RuntimeError(f"Godot export did not produce a nonempty artifact: {resolved}")
    return resolved


def portable_command(
    command: list[str],
    godot: pathlib.Path,
    repo_root: pathlib.Path,
    temporary: str,
    group_evidence: pathlib.Path,
) -> list[str]:
    """Remove host-specific executable paths from tracked result records."""

    rendered: list[str] = []
    for item in command:
        if pathlib.Path(item) == godot:
            rendered.append("{godot}")
        elif pathlib.Path(item).name.lower() in ("xvfb-run", "xvfb-run.exe"):
            rendered.append("{xvfb-run}")
        elif item == str(repo_root):
            rendered.append("{repo}")
        elif item == temporary:
            rendered.append("{temp}")
        elif item == str(group_evidence):
            rendered.append("{evidence}")
        else:
            rendered.append(item)
    return rendered


def decoded_output(value: str | bytes | None) -> str:
    """Normalize subprocess timeout output without losing useful diagnostics."""

    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


def parse_godot_result(stdout: str) -> dict[str, object]:
    for line in reversed(stdout.splitlines()):
        if line.startswith(GODOT_RESULT_PREFIX):
            value = json.loads(line.removeprefix(GODOT_RESULT_PREFIX))
            if not isinstance(value, dict):
                break
            return value
    raise ValueError("Godot did not emit a structured test result.")


def deployment_lifecycle_payload(temporary_root: pathlib.Path) -> dict[str, object]:
    """Exercise deployment resumption without contacting or modifying a device."""

    fake_repo = temporary_root / "repo"
    artifact = fake_repo / ".build" / "artifacts" / "android" / "AstroTops.apk"
    artifact.parent.mkdir(parents=True)
    artifact.write_bytes(b"qualified-astrotops-apk")
    expected_hash = hashlib.sha256(artifact.read_bytes()).hexdigest()
    device = "192.0.2.10:12345"
    package = "com.ceratopscode.astrotops"
    activity = package + "/com.godot.game.GodotAppLauncher"
    remote_path = "/data/app/~~probe/com.ceratopscode.astrotops-probe/base.apk"
    failures: list[dict[str, object]] = []
    observations: list[dict[str, object]] = []
    assertions = 0

    def check(identifier: str, expected: object, actual: object) -> None:
        nonlocal assertions
        assertions += 1
        observations.append({"id": identifier, "actual": actual})
        if actual != expected:
            failures.append({"id": identifier, "expected": expected, "actual": actual})

    class FakeAdb:
        def __init__(self, installed_hash: str | None, connect_output: str) -> None:
            self.installed_hash = installed_hash
            self.connect_output = connect_output
            self.installs = 0
            self.launches = 0

        def __call__(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
            if arguments[1:2] == ["connect"]:
                return subprocess.CompletedProcess(arguments, 0, self.connect_output + "\n", "")
            if arguments[-3:] == ["pm", "path", package]:
                output = f"package:{remote_path}\n" if self.installed_hash else ""
                return subprocess.CompletedProcess(arguments, 0, output, "")
            if len(arguments) >= 2 and arguments[-2] == "sha256sum":
                output = f"{self.installed_hash}  {remote_path}\n"
                return subprocess.CompletedProcess(arguments, 0, output, "")
            if "install" in arguments:
                self.installs += 1
                self.installed_hash = expected_hash
                return subprocess.CompletedProcess(arguments, 0, "Success\n", "")
            if arguments[-5:-2] == ["am", "start", "-W"]:
                self.launches += 1
                return subprocess.CompletedProcess(arguments, 0, "Status: ok\n", "")
            return subprocess.CompletedProcess(arguments, 97, "", "unexpected fake ADB command")

    exact = FakeAdb(expected_hash, f"connected to {device}")
    exact_receipt = android_deploy_result(
        fake_repo,
        adb_executable="adb",
        device=device,
        package=package,
        activity=activity,
        artifact=artifact,
        artifact_type="android-apk",
        run=exact,
    )
    check("exact-apk-skips-install", 0, exact.installs)
    check("exact-apk-launches", 1, exact.launches)
    check("deployment-receipt-schema", "ceratops-deployment-result.v1", exact_receipt.get("schema"))
    descriptor = exact_receipt.get("artifact")
    check(
        "deployment-receipt-hash",
        expected_hash,
        descriptor.get("sha256") if isinstance(descriptor, dict) else None,
    )

    changed = FakeAdb("0" * 64, f"already connected to {device}")
    android_deploy_result(
        fake_repo,
        adb_executable="adb",
        device=device,
        package=package,
        activity=activity,
        artifact=artifact,
        artifact_type="android-apk",
        run=changed,
    )
    check("changed-apk-installs-once", 1, changed.installs)
    check("installed-apk-is-verified", expected_hash, changed.installed_hash)

    false_success = FakeAdb(expected_hash, f"cannot connect to {device}")
    try:
        android_deploy_result(
            fake_repo,
            adb_executable="adb",
            device=device,
            package=package,
            activity=activity,
            artifact=artifact,
            artifact_type="android-apk",
            run=false_success,
        )
    except ValueError as error:
        connection_error = "did not establish" in str(error)
    else:
        connection_error = False
    check("false-success-connect-is-rejected", True, connection_error)

    import_calls: list[tuple[list[str], dict[str, object]]] = []

    def fake_import_run(
        command: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        import_calls.append((command, kwargs))
        return subprocess.CompletedProcess(command, 0, "Imported project assets.\n", "")

    fake_godot = temporary_root / "godot"
    bootstrap_godot_imports(fake_repo, fake_godot, run=fake_import_run)
    check(
        "runner-import-command",
        [str(fake_godot), "--headless", "--path", str(fake_repo), "--import"],
        import_calls[0][0],
    )
    check(
        "runner-import-working-directory",
        str(fake_repo),
        str(import_calls[0][1].get("cwd")),
    )

    fake_archive = temporary_root / "godot-runtime.zip"
    fake_members = ["godot-test", "godot-test-helper"]
    with zipfile.ZipFile(fake_archive, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        archive.writestr(fake_members[0], b"pinned-godot-runtime")
        archive.writestr(fake_members[1], b"pinned-godot-helper")
    fake_spec: dict[str, object] = {
        "url": "https://example.invalid/godot.zip",
        "sha256": _sha256(fake_archive),
        "size": fake_archive.stat().st_size,
        "members": fake_members,
        "executable": fake_members[0],
    }
    download_count = 0

    def fake_download(_url: str, destination: pathlib.Path) -> None:
        nonlocal download_count
        download_count += 1
        shutil.copyfile(fake_archive, destination)

    def fake_version(_executable: pathlib.Path) -> str:
        return GODOT_VERSION + ".stable.test"

    fake_cache = temporary_root / "tool-cache" / "godot"
    provisioned = provision_godot(
        cache_root=fake_cache,
        spec=fake_spec,
        download=fake_download,
        version_probe=fake_version,
    )
    check("godot-provision-downloads-once", 1, download_count)
    check("godot-provisioned-runtime-exists", True, provisioned.is_file())
    reused = provision_godot(
        cache_root=fake_cache,
        spec=fake_spec,
        download=fake_download,
        version_probe=fake_version,
    )
    check("godot-valid-cache-is-reused", 1, download_count)
    check("godot-cache-path-is-stable", str(provisioned), str(reused))
    provisioned.write_bytes(b"tampered")
    repaired = provision_godot(
        cache_root=fake_cache,
        spec=fake_spec,
        download=fake_download,
        version_probe=fake_version,
    )
    check("godot-tampered-cache-is-repaired", 2, download_count)
    check(
        "godot-repair-restores-runtime",
        "pinned-godot-runtime",
        repaired.read_bytes().decode("ascii"),
    )

    bad_spec = dict(fake_spec)
    bad_spec["sha256"] = "0" * 64
    try:
        provision_godot(
            cache_root=temporary_root / "bad-tool-cache" / "godot",
            spec=bad_spec,
            download=fake_download,
            version_probe=fake_version,
        )
    except RuntimeError as error:
        checksum_rejected = "integrity check failed" in str(error)
    else:
        checksum_rejected = False
    check("godot-bad-archive-is-rejected", True, checksum_rejected)

    for index, version in enumerate(("4.6.1", "4.6.2", "4.6.3"), start=1):
        predecessor = fake_cache / version
        predecessor.mkdir()
        os.utime(predecessor, (float(index), float(index)))
    _prune_godot_cache(fake_cache, GODOT_VERSION)
    retained_versions = sorted(
        path.name for path in fake_cache.iterdir() if path.is_dir() and not path.name.startswith(".")
    )
    check("godot-cache-retention-is-bounded", ["4.6.2", "4.6.3", GODOT_VERSION], retained_versions)

    resolved = resolve_godot(
        None,
        environ={},
        which=lambda _name: None,
        provision=lambda: repaired,
        version_probe=fake_version,
    )
    check("godot-missing-path-self-provisions", str(repaired), str(resolved))
    mismatched = temporary_root / "godot-4.6"
    mismatched.write_bytes(b"older-godot-runtime")

    def resolver_version(executable: pathlib.Path) -> str:
        if executable == mismatched:
            return "4.6.0.stable.test"
        return fake_version(executable)

    resolved_from_mismatch = resolve_godot(
        None,
        environ={},
        which=lambda name: str(mismatched) if name == "godot" else None,
        provision=lambda: repaired,
        version_probe=resolver_version,
    )
    check(
        "godot-mismatched-path-self-provisions",
        str(repaired),
        str(resolved_from_mismatch),
    )

    operation_calls: list[list[str]] = []

    def fake_godot_run(
        command: list[str], **_kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        operation_calls.append(command)
        if "--export-debug" in command:
            pathlib.Path(command[-1]).write_bytes(b"debug-apk")
        return subprocess.CompletedProcess(command, 0, "", "")

    validate_godot_project(fake_repo, repaired, run=fake_godot_run)
    check(
        "godot-project-validation-command",
        [str(repaired), "--headless", "--editor", "--path", str(fake_repo), "--quit"],
        operation_calls[0],
    )
    exported = export_debug_project(
        fake_repo,
        repaired,
        pathlib.Path(".build/artifacts/android/provisioned.apk"),
        run=fake_godot_run,
    )
    check(
        "godot-export-produces-artifact",
        "debug-apk",
        exported.read_bytes().decode("ascii"),
    )

    merged_source = SourceIdentity(
        commit="synthetic-merge",
        digest="source-digest",
        exact_tags=(),
        dirty_paths=(),
    )
    tagged_artifact = ArtifactIdentity(
        version="astrotops-local-test",
        source_commit="tagged-source",
        path=".build/artifacts/android/AstroTops.apk",
        sha256=expected_hash,
        length=artifact.stat().st_size,
    )
    check(
        "delivery-validation-survives-content-identical-merge",
        True,
        qualification_source_matches(
            {"commit": "tagged-source", "digest": "source-digest"},
            merged_source,
            tagged_artifact,
        ),
    )
    check(
        "delivery-validation-rejects-different-content",
        False,
        qualification_source_matches(
            {"commit": "tagged-source", "digest": "different-digest"},
            merged_source,
            tagged_artifact,
        ),
    )
    check(
        "delivery-validation-rejects-unqualified-commit",
        False,
        qualification_source_matches(
            {"commit": "unrelated-source", "digest": "source-digest"},
            merged_source,
            tagged_artifact,
        ),
    )
    return {
        "group": "delivery-lifecycle",
        "status": "passed" if not failures else "failed",
        "assertions": assertions,
        "failures": failures,
        "observations": observations,
        "evidence": [],
    }


def run_python_group(
    group_id: str,
    fingerprint: str,
    source: dict[str, object],
    environment: dict[str, object],
    group_evidence: pathlib.Path,
    run_id: str,
    artifact: dict[str, object] | None,
    started: float,
) -> dict[str, object]:
    """Run one in-process infrastructure group with isolated test data."""

    with tempfile.TemporaryDirectory(prefix=f"astrotops-{group_id}-") as temporary:
        if group_id == "delivery-lifecycle":
            payload = deployment_lifecycle_payload(pathlib.Path(temporary))
        else:
            payload = {
                "group": group_id,
                "status": "failed",
                "assertions": 0,
                "failures": [
                    {
                        "id": "runner/python-group",
                        "expected": "registered Python group",
                        "actual": group_id,
                    }
                ],
                "observations": [],
                "evidence": [],
            }
    raw_failures = payload.get("failures")
    if not isinstance(raw_failures, list) or not all(
        isinstance(item, dict) for item in raw_failures
    ):
        raise TypeError("Python-group failures must be a list of objects")
    failures = [dict(item) for item in raw_failures]
    passed = payload["status"] == "passed" and not failures
    log_path = group_evidence / "output.log"
    log_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
        newline="\n",
    )
    for failure in failures:
        print(
            f"{group_id}/{failure.get('id')} "
            f"expected={failure.get('expected')} actual={failure.get('actual')}",
            file=sys.stderr,
        )
    return {
        "schema": GROUP_SCHEMA,
        "id": group_id,
        "status": "passed" if passed else "failed",
        "outcome": "passed" if passed else "failed",
        "execution": "executed",
        "fingerprint": fingerprint,
        "exitCode": 0 if passed else 1,
        "seconds": round(time.time() - started, 3),
        "runId": run_id,
        "source": source,
        "environment": environment,
        "artifact": artifact,
        "command": ["{python}", "scripts/run-tests.py", "--group", group_id],
        "assertions": payload["assertions"],
        "failures": failures,
        "observations": payload["observations"],
        "evidence": [
            log_path.relative_to(group_evidence.parents[2]).as_posix()
        ],
        "finishedAt": time.time(),
    }


def run_group(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    definition: dict[str, object],
    fingerprint: str,
    source: dict[str, object],
    environment: dict[str, object],
    evidence_root: pathlib.Path,
    run_id: str,
    artifact: dict[str, object] | None,
) -> dict[str, object]:
    """Run one isolated group and preserve its exact observable outcome."""

    group_id = str(definition["id"])
    mode = str(definition["mode"])
    group_evidence = evidence_root / group_id
    group_evidence.mkdir(parents=True, exist_ok=True)
    started = time.time()
    if mode == "python":
        return run_python_group(
            group_id,
            fingerprint,
            source,
            environment,
            group_evidence,
            run_id,
            artifact,
            started,
        )
    with tempfile.TemporaryDirectory(prefix=f"astrotops-{group_id}-") as temporary:
        command: list[str] = []
        if mode == "rendered" and sys.platform.startswith("linux"):
            xvfb = shutil.which("xvfb-run")
            if not xvfb:
                return {
                    "schema": GROUP_SCHEMA,
                    "id": group_id,
                    "status": "blocked",
                    "outcome": "blocked",
                    "execution": "not-run",
                    "fingerprint": fingerprint,
                    "exitCode": 1,
                    "seconds": 0.0,
                    "source": source,
                    "environment": environment,
                    "artifact": artifact,
                    "runId": run_id,
                    "failures": [{"id": "runner/xvfb", "expected": "xvfb-run on PATH", "actual": "missing"}],
                    "observations": [],
                    "evidence": [],
                }
            command.extend([xvfb, "-a"])
        command.append(str(godot))
        if mode == "headless":
            command.append("--headless")
        else:
            command.extend(["--rendering-method", "gl_compatibility", "--audio-driver", "Dummy"])
        command.extend(
            [
                "--path",
                str(repo_root),
                "--script",
                "scripts/regression_tests.gd",
                "--",
                "--group",
                group_id,
                "--temp-root",
                temporary,
                "--evidence-root",
                str(group_evidence),
            ]
        )
        try:
            completed = subprocess.run(
                command,
                cwd=repo_root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
                timeout=120,
            )
            stdout = completed.stdout
            stderr = completed.stderr
            exit_code = completed.returncode
        except subprocess.TimeoutExpired as error:
            stdout = decoded_output(error.stdout)
            stderr = decoded_output(error.stderr) + "\nTimed out after 120 seconds."
            exit_code = 124
    log_path = group_evidence / "output.log"
    log_path.write_text(
        "stdout:\n" + stdout + "\nstderr:\n" + stderr,
        encoding="utf-8",
        newline="\n",
    )
    failures: list[dict[str, object]]
    observations: list[dict[str, object]]
    assertions = 0
    generated_evidence: list[str] = []
    try:
        payload = parse_godot_result(stdout)
        raw_failures = payload.get("failures", [])
        raw_observations = payload.get("observations", [])
        raw_assertions = payload.get("assertions", 0)
        raw_evidence = payload.get("evidence", [])
        if not isinstance(raw_failures, list) or not all(isinstance(item, dict) for item in raw_failures):
            raise TypeError("failures must be a list of objects")
        if not isinstance(raw_observations, list) or not all(isinstance(item, dict) for item in raw_observations):
            raise TypeError("observations must be a list of objects")
        if not isinstance(raw_assertions, int):
            raise TypeError("assertions must be an integer")
        if not isinstance(raw_evidence, list):
            raise TypeError("evidence must be a list")
        failures = [dict(item) for item in raw_failures]
        observations = [dict(item) for item in raw_observations]
        assertions = raw_assertions
        generated_evidence = [str(item) for item in raw_evidence]
        if payload.get("group") != group_id:
            failures.append({"id": "runner/group-result", "expected": group_id, "actual": payload.get("group")})
        if payload.get("status") != "passed":
            failures.append(
                {
                    "id": "runner/group-status",
                    "expected": "passed",
                    "actual": payload.get("status"),
                }
            )
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        failures = [{"id": "runner/structured-result", "expected": "valid Godot result", "actual": str(error)}]
        observations = []
    runtime_errors = [
        line.strip()
        for line in stderr.splitlines()
        if line.startswith("SCRIPT ERROR:") or line.startswith("ERROR:")
    ]
    if runtime_errors:
        failures.append(
            {
                "id": "runner/godot-runtime",
                "expected": "no Godot runtime errors",
                "actual": " | ".join(runtime_errors[:4]),
            }
        )
    passed = exit_code == 0 and not failures
    evidence_paths = [
        (path.relative_to(repo_root / ".test-results")).as_posix()
        for path in sorted(group_evidence.iterdir())
        if path.is_file()
    ]
    for name in generated_evidence:
        expected_path = group_evidence / name
        if expected_path.is_file():
            relative = expected_path.relative_to(repo_root / ".test-results").as_posix()
            if relative not in evidence_paths:
                evidence_paths.append(relative)
    result: dict[str, object] = {
        "schema": GROUP_SCHEMA,
        "id": group_id,
        "status": "passed" if passed else "failed",
        "outcome": "passed" if passed else "failed",
        "execution": "executed",
        "fingerprint": fingerprint,
        "exitCode": exit_code if exit_code else (0 if passed else 1),
        "seconds": round(time.time() - started, 3),
        "runId": run_id,
        "source": source,
        "environment": environment,
        "artifact": artifact,
        "command": portable_command(command, godot, repo_root, temporary, group_evidence),
        "assertions": assertions,
        "failures": failures,
        "observations": observations,
        "evidence": sorted(evidence_paths),
        "finishedAt": time.time(),
    }
    for failure in failures:
        print(
            f"{group_id}/{failure.get('id')} "
            f"expected={failure.get('expected')} actual={failure.get('actual')}",
            file=sys.stderr,
        )
    return result


def load_group_result(path: pathlib.Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) and value.get("schema") == GROUP_SCHEMA else None


def qualification_source_matches(
    recorded_source: object,
    source_identity: SourceIdentity,
    artifact_identity: ArtifactIdentity,
) -> bool:
    """Bind validation to the tagged source while tolerating a content-identical merge commit."""

    return (
        isinstance(recorded_source, dict)
        and recorded_source.get("commit") == artifact_identity.source_commit
        and recorded_source.get("digest") == source_identity.digest
    )


def applicable_qualified_artifact(
    repo_root: pathlib.Path,
    source_identity: SourceIdentity,
) -> ArtifactIdentity | None:
    """Reuse qualification only while source and exact artifact bytes still match."""

    try:
        report = json.loads(
            (repo_root / ".test-results" / "tests.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        return None
    source = report.get("source") if isinstance(report, dict) else None
    artifact = report.get("artifact") if isinstance(report, dict) else None
    if (
        not isinstance(report, dict)
        or report.get("schema") != RESULT_SCHEMA
        or report.get("outcome") != "passed"
        or not isinstance(source, dict)
        or source.get("commit") != source_identity.commit
        or source.get("digest") != source_identity.digest
        or not isinstance(artifact, dict)
    ):
        return None
    version = artifact.get("version")
    relative = artifact.get("artifactPath")
    if not isinstance(version, str) or not isinstance(relative, str):
        return None
    try:
        resolved = resolve_artifact_identity(
            repo_root,
            source_identity,
            version,
            repo_root.joinpath(*pathlib.PurePosixPath(relative).parts),
        )
    except (OSError, ValueError, subprocess.SubprocessError):
        return None
    if resolved is None or resolved.portable() != artifact:
        return None
    return resolved


def reused_result(previous: dict[str, object], source: dict[str, object]) -> dict[str, object]:
    result = dict(previous)
    result.update(
        status="reused",
        outcome="passed",
        execution="reused",
        exitCode=0,
        seconds=0.0,
        source=source,
        originalFinishedAt=previous.get("finishedAt"),
        originalRunId=previous.get("runId"),
    )
    return result


def verify_delivery(
    repo_root: pathlib.Path,
    inventory: dict[str, object],
    groups: list[dict[str, object]],
    source_identity: SourceIdentity,
    artifact_identity: ArtifactIdentity,
    store: ResultStore,
) -> int:
    """Verify retained passing results and exact package bytes without testing again."""

    if source_identity.dirty_paths:
        print(
            "delivery/source expected=clean source actual="
            + ", ".join(source_identity.dirty_paths[:8]),
            file=sys.stderr,
        )
        return 1
    file_owners = inventory.get("fileOwners")
    if not isinstance(file_owners, dict):
        print("delivery/inventory expected=file ownership map actual=missing", file=sys.stderr)
        return 1
    artifact = artifact_identity.portable()
    failures: list[str] = []
    try:
        validation = json.loads(
            (store.result_root / "validation.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        validation = None
    if not isinstance(validation, dict) or validation.get("schema") != VALIDATION_SCHEMA:
        failures.append("delivery/validation expected=valid repository result actual=missing or invalid")
    else:
        validation_source = validation.get("source")
        validation_results = validation.get("results")
        required_validation = validation.get("requiredChecks")
        if validation.get("outcome") != "passed":
            failures.append(
                f"delivery/validation expected=passed actual={validation.get('outcome')}"
            )
        if not qualification_source_matches(
            validation_source, source_identity, artifact_identity
        ):
            failures.append("delivery/validation expected=applicable result actual=stale")
        if (
            not isinstance(required_validation, list)
            or not required_validation
            or not isinstance(validation_results, list)
            or [item.get("id") for item in validation_results if isinstance(item, dict)]
            != required_validation
            or any(
                item.get("outcome") != "passed"
                for item in validation_results
                if isinstance(item, dict)
            )
        ):
            failures.append("delivery/validation expected=complete passing checks actual=incomplete")
    group_ids: list[str] = []
    for definition in groups:
        group_id = str(definition["id"])
        group_ids.append(group_id)
        previous = load_group_result(store.group_root / f"{group_id}.json")
        if previous is None:
            failures.append(f"delivery/{group_id} expected=recorded pass actual=missing")
            continue
        environment = previous.get("environment")
        if not isinstance(environment, dict):
            failures.append(f"delivery/{group_id} expected=recorded environment actual=missing")
            continue
        owned_paths = [
            str(relative)
            for relative, owners in file_owners.items()
            if isinstance(owners, list) and group_id in owners
        ]
        fingerprint = group_fingerprint(
            repo_root, group_id, owned_paths, environment, artifact_identity
        )
        if previous.get("outcome") != "passed":
            failures.append(
                f"delivery/{group_id} expected=passed actual={previous.get('outcome')}"
            )
        elif previous.get("fingerprint") != fingerprint:
            failures.append(f"delivery/{group_id} expected=applicable result actual=stale")
        elif previous.get("artifact") != artifact:
            failures.append(f"delivery/{group_id} expected=exact artifact actual=different")

    try:
        loaded_report = json.loads((store.result_root / "tests.json").read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        loaded_report = None
    if not isinstance(loaded_report, dict) or loaded_report.get("schema") != RESULT_SCHEMA:
        failures.append("delivery/report expected=valid repository result actual=missing or invalid")
    else:
        if loaded_report.get("outcome") != "passed":
            failures.append(
                f"delivery/report expected=passed actual={loaded_report.get('outcome')}"
            )
        if loaded_report.get("artifact") != artifact:
            failures.append("delivery/report expected=exact artifact actual=different")
        if loaded_report.get("requiredChecks") != group_ids:
            failures.append("delivery/report expected=complete group coverage actual=incomplete")

    try:
        build = json.loads(store.build_path(artifact_identity).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        build = None
    if not isinstance(build, dict):
        failures.append("delivery/build expected=tracked build metadata actual=missing or invalid")
    else:
        for key, value in {
            **artifact,
            "sourceDigest": source_identity.digest,
        }.items():
            if build.get(key) != value:
                failures.append(
                    f"delivery/build.{key} expected={value} actual={build.get(key)}"
                )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1
    print("OK")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=pathlib.Path, default=_SCRIPT_DIRECTORY.parent)
    parser.add_argument("--scope", choices=("repository",), default="repository")
    parser.add_argument("--group", action="append", default=[])
    parser.add_argument("--fresh", action="store_true")
    parser.add_argument("--godot", type=pathlib.Path)
    parser.add_argument("--no-record", action="store_true")
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--prepare-godot",
        action="store_true",
        help="Resolve or provision the pinned Godot runtime and stop.",
    )
    mode.add_argument(
        "--validate-project",
        action="store_true",
        help="Parse the project with the pinned Godot editor and stop.",
    )
    mode.add_argument(
        "--export-debug",
        type=pathlib.Path,
        help="Export the Android debug artifact to a repository-relative path and stop.",
    )
    mode.add_argument(
        "--verify-delivery",
        action="store_true",
        help="Verify retained results and exact artifact bytes without executing tests.",
    )
    parser.add_argument("--source-tag")
    parser.add_argument("--artifact", type=pathlib.Path)
    args = parser.parse_args()

    repo_root = args.repo_root.expanduser().resolve(strict=True)
    lifecycle_mode = bool(
        args.prepare_godot or args.validate_project or args.export_debug is not None
    )
    if lifecycle_mode:
        if args.group or args.fresh or args.no_record or args.source_tag or args.artifact:
            parser.error(
                "Godot lifecycle modes cannot be combined with test or delivery options."
            )
        try:
            godot = resolve_godot(args.godot)
            if args.validate_project:
                validate_godot_project(repo_root, godot)
            elif args.export_debug is not None:
                export_debug_project(repo_root, godot, args.export_debug)
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
            print(str(error), file=sys.stderr)
            return 1
        print("OK")
        return 0

    try:
        inventory, groups = load_inventory(repo_root)
        group_ids = [str(item["id"]) for item in groups]
        unknown = sorted(set(args.group) - set(group_ids))
        if unknown:
            parser.error(f"Unknown test groups: {unknown}")
        source_identity = resolve_source_identity(repo_root)
        artifact_identity = resolve_artifact_identity(
            repo_root, source_identity, args.source_tag, args.artifact
        )
        if artifact_identity is None:
            artifact_identity = applicable_qualified_artifact(
                repo_root, source_identity
            )
        store = ResultStore(
            repo_root,
            source_identity,
            record=not args.no_record and not args.verify_delivery,
        )
        if args.verify_delivery:
            if args.fresh or args.group or args.no_record:
                raise ValueError("--verify-delivery cannot be combined with execution options.")
            if artifact_identity is None:
                raise ValueError("--verify-delivery requires --source-tag and --artifact.")
            return verify_delivery(
                repo_root,
                inventory,
                groups,
                source_identity,
                artifact_identity,
                store,
            )
        godot = resolve_godot(args.godot)
        environment: dict[str, object] = {
            "godot": godot_version(godot),
            "platform": platform.system().lower(),
            "python": platform.python_version(),
            "renderer": "gl_compatibility",
        }
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        return 1

    selected = set(args.group or group_ids)
    started = time.time()
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    run_id = f"{timestamp}-{source_identity.commit[:12]}"
    evidence_root = store.begin_evidence_run(run_id)
    explicit_selection = bool(args.group)
    source = source_identity.portable()
    artifact = artifact_identity.portable() if artifact_identity else None
    file_owners = inventory["fileOwners"]
    if not isinstance(file_owners, dict):
        print("The test inventory has no valid file ownership map.", file=sys.stderr)
        return 1
    results: list[dict[str, object]] = []
    imports_bootstrapped = False

    for definition in groups:
        group_id = str(definition["id"])
        owned_paths = [
            str(relative)
            for relative, owners in file_owners.items()
            if isinstance(owners, list) and group_id in owners
        ]
        fingerprint = group_fingerprint(
            repo_root, group_id, owned_paths, environment, artifact_identity
        )
        previous = load_group_result(store.group_root / f"{group_id}.json")
        applicable_pass = bool(
            previous
            and previous.get("outcome") == "passed"
            and previous.get("fingerprint") == fingerprint
            and previous.get("artifact") == artifact
        )
        must_execute = group_id in selected and (
            args.fresh or explicit_selection or not applicable_pass
        )
        if must_execute:
            if definition["mode"] != "python" and not imports_bootstrapped:
                try:
                    bootstrap_godot_imports(repo_root, godot)
                except (OSError, RuntimeError, subprocess.SubprocessError) as error:
                    print(str(error), file=sys.stderr)
                    return 1
                imports_bootstrapped = True
            result = run_group(
                repo_root,
                godot,
                definition,
                fingerprint,
                source,
                environment,
                evidence_root,
                run_id,
                artifact,
            )
            store.write_group(group_id, result)
        elif applicable_pass and previous is not None:
            result = reused_result(previous, source)
        else:
            result = {
                "schema": GROUP_SCHEMA,
                "id": group_id,
                "status": "stale",
                "outcome": "stale",
                "execution": "not-run",
                "fingerprint": fingerprint,
                "exitCode": 1,
                "seconds": 0.0,
                "source": source,
                "environment": environment,
                "artifact": artifact,
                "runId": run_id,
                "failures": [{"id": "runner/applicability", "expected": "applicable passing result", "actual": "missing or stale"}],
                "observations": [],
                "evidence": [],
            }
        results.append(result)

    passed = all(result.get("outcome") == "passed" for result in results)
    report: dict[str, object] = {
        "schema": RESULT_SCHEMA,
        "stage": "tests",
        "requestedScope": args.scope,
        "coverageStatus": "complete-repository" if passed else "failed",
        "status": "passed" if passed else "failed",
        "outcome": "passed" if passed else "failed",
        "execution": "reused" if results and all(result.get("execution") == "reused" for result in results) else "executed",
        "runId": run_id,
        "source": source,
        "artifact": artifact,
        "requiredChecks": group_ids,
        "selectedChecks": sorted(selected),
        "startedAt": started,
        "finishedAt": time.time(),
        "results": results,
    }
    report_path = store.result_root / "tests.json"
    if report["execution"] != "reused" or not report_path.is_file():
        store.write_report(report)
    if artifact_identity is not None:
        store.write_build(artifact_identity, source_identity.digest)
    store.prune_evidence(keep={run_id})
    if passed:
        print("OK")
        return 0
    failed = [str(result["id"]) for result in results if result.get("outcome") != "passed"]
    print(json.dumps({"status": "failed", "groups": failed, "runId": run_id}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
