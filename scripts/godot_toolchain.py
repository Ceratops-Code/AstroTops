#!/usr/bin/env python3
"""Own AstroTops' pinned Godot editor and Android build-template lifecycle.

The module resolves caller-provided runtimes first, otherwise it provisions
official, hash-pinned artifacts into a bounded user cache without changing the
system installation or persistent ``PATH``. Android exports install a verified
source template into the ignored repository ``android`` directory only when it
is absent; an unexpected existing directory is preserved and reported instead
of being overwritten. Android shipping validation preflights the JDK and SDK,
performs a real debug export, and runs Gradle lint through the installed source
template before any remote shipping mutation.
"""

from __future__ import annotations

import hashlib
import json
import os
import pathlib
import platform
import shutil
import stat
import subprocess
import tempfile
import time
import urllib.request
import zipfile
from collections.abc import Callable, Iterable, Mapping

from remotezip import RemoteZip  # type: ignore[import-untyped]

GODOT_VERSION = "4.7.2"
GODOT_TEMPLATE_IDENTIFIER = "4.7.2.stable"
GODOT_CACHE_SCHEMA = "astrotops-godot-cache.v1"
ANDROID_TEMPLATE_CACHE_SCHEMA = "astrotops-android-template-cache.v1"
ANDROID_PROJECT_TEMPLATE_SCHEMA = "astrotops-android-project-template.v1"
CACHE_PREDECESSORS = 2
CACHE_LOCK_STALE_SECONDS = 900.0
CACHE_LOCK_WAIT_SECONDS = 120.0
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
ANDROID_SOURCE_TEMPLATE: dict[str, object] = {
    "url": "https://downloads.godotengine.org/?version=4.7.2&flavor=stable&slug=export_templates.tpz&platform=templates",
    "member": "templates/android_source.zip",
    "filename": "android_source.zip",
    "sha256": "a15416b528efb0a19a7d187e4d9f4e5336d0689144b111329fb4bd12c4447ad3",
    "size": 214_418_211,
}


def _sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _matches_pinned_file(path: pathlib.Path, spec: Mapping[str, object]) -> bool:
    expected_size = spec.get("size")
    expected_hash = spec.get("sha256")
    return bool(
        isinstance(expected_size, int)
        and isinstance(expected_hash, str)
        and path.is_file()
        and path.stat().st_size == expected_size
        and _sha256(path) == expected_hash
    )


def tool_cache_root(environ: Mapping[str, str] | None = None) -> pathlib.Path:
    """Return the user-cache root owned by the AstroTops toolchain helper."""

    values = os.environ if environ is None else environ
    override = values.get("ASTROTOPS_TOOL_CACHE")
    if override:
        return pathlib.Path(override).expanduser().resolve()
    if platform.system().lower() == "windows":
        base = pathlib.Path(
            values.get("LOCALAPPDATA", pathlib.Path.home() / "AppData" / "Local")
        )
        return base / "Ceratops" / "AstroTops" / "tools"
    base = pathlib.Path(values.get("XDG_CACHE_HOME", pathlib.Path.home() / ".cache"))
    return base / "ceratops" / "astrotops" / "tools"


def godot_cache_root(environ: Mapping[str, str] | None = None) -> pathlib.Path:
    return tool_cache_root(environ) / "godot"


def android_template_cache_root(
    environ: Mapping[str, str] | None = None,
) -> pathlib.Path:
    return tool_cache_root(environ) / "android-template"


class _CacheLock:
    """Serialize one cache mutation and recover demonstrably stale owners."""

    def __init__(self, root: pathlib.Path, name: str = ".provision-lock") -> None:
        self.path = root / name
        self.token = f"{os.getpid()}-{time.time_ns()}"

    def __enter__(self) -> None:
        deadline = time.monotonic() + CACHE_LOCK_WAIT_SECONDS
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
                        f"Tool cache lock has an invalid type: {self.path}"
                    ) from error
                age = time.time() - self.path.stat().st_mtime
                if age > CACHE_LOCK_STALE_SECONDS:
                    shutil.rmtree(self.path)
                    continue
                if time.monotonic() >= deadline:
                    raise RuntimeError(
                        f"Timed out waiting for tool cache lock: {self.path}"
                    ) from error
                time.sleep(0.25)

    def __exit__(self, *_error: object) -> None:
        owner = self.path / "owner"
        try:
            if owner.read_text(encoding="utf-8").strip() == self.token:
                shutil.rmtree(self.path)
        except FileNotFoundError:
            return


def _cleanup_cache_orphans(root: pathlib.Path) -> None:
    """Remove interrupted helper-owned downloads and extraction directories."""

    for child in root.iterdir():
        if not child.name.startswith((".download-", ".extract-")):
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def _prune_version_cache(root: pathlib.Path, current_version: str) -> None:
    """Retain the current version and at most two most-recent predecessors."""

    predecessors = [
        child
        for child in root.iterdir()
        if child.is_dir()
        and not child.is_symlink()
        and not child.name.startswith(".")
        and child.name != current_version
    ]
    predecessors.sort(key=lambda path: path.stat().st_mtime, reverse=True)
    for obsolete in predecessors[CACHE_PREDECESSORS:]:
        shutil.rmtree(obsolete)


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


def _download_godot_archive(url: str, destination: pathlib.Path) -> None:
    """Download one official editor archive without global installer state."""

    request = urllib.request.Request(url, headers={"User-Agent": "AstroTops-tool-bootstrap/1"})
    with urllib.request.urlopen(request, timeout=120) as response:
        with destination.open("wb") as output:
            shutil.copyfileobj(response, output, length=1024 * 1024)


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
    """Provision the pinned editor atomically in the bounded tool cache."""

    selected = dict(spec or godot_archive_spec())
    root = (cache_root or godot_cache_root()).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    with _CacheLock(root):
        _cleanup_cache_orphans(root)
        version_root = root / GODOT_VERSION
        cached = _cached_godot(version_root, selected, version_probe=version_probe)
        if cached is not None:
            os.utime(version_root)
            _prune_version_cache(root, GODOT_VERSION)
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
            member_hashes = _extract_godot_archive(archive_path, extraction_root, members)
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
        _prune_version_cache(root, GODOT_VERSION)
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


def _download_remote_zip_member(
    url: str,
    member: str,
    destination: pathlib.Path,
) -> None:
    """Fetch one ZIP member by HTTP range instead of the complete template bundle."""

    with RemoteZip(
        url,
        headers={"User-Agent": "AstroTops-tool-bootstrap/1"},
        timeout=120,
    ) as archive:
        info = archive.getinfo(member)
        with archive.open(info) as source, destination.open("wb") as output:
            shutil.copyfileobj(source, output, length=1024 * 1024)


def _installed_android_source_candidates(
    environ: Mapping[str, str],
    system_name: str | None = None,
) -> list[pathlib.Path]:
    system = (system_name or platform.system()).lower()
    if system == "windows":
        base = pathlib.Path(
            environ.get("APPDATA", pathlib.Path.home() / "AppData" / "Roaming")
        ) / "Godot"
    elif system == "darwin":
        base = pathlib.Path.home() / "Library" / "Application Support" / "Godot"
    else:
        data_home = pathlib.Path(
            environ.get("XDG_DATA_HOME", pathlib.Path.home() / ".local" / "share")
        )
        base = data_home / "godot"
    return [
        base
        / "export_templates"
        / GODOT_TEMPLATE_IDENTIFIER
        / "android_source.zip"
    ]


def _cached_android_source(
    version_root: pathlib.Path,
    spec: Mapping[str, object],
) -> pathlib.Path | None:
    filename = spec.get("filename")
    if not isinstance(filename, str):
        return None
    source = version_root / filename
    manifest_path = version_root / "manifest.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    expected = {
        "schema": ANDROID_TEMPLATE_CACHE_SCHEMA,
        "version": GODOT_TEMPLATE_IDENTIFIER,
        "member": spec.get("member"),
        "sha256": spec.get("sha256"),
        "size": spec.get("size"),
    }
    if not isinstance(manifest, dict) or any(
        manifest.get(key) != value for key, value in expected.items()
    ):
        return None
    return source if _matches_pinned_file(source, spec) else None


def provision_android_source_template(
    *,
    cache_root: pathlib.Path | None = None,
    spec: Mapping[str, object] | None = None,
    environ: Mapping[str, str] | None = None,
    installed_candidates: Iterable[pathlib.Path] | None = None,
    download: Callable[[str, str, pathlib.Path], None] = _download_remote_zip_member,
) -> pathlib.Path:
    """Provision only the verified Android source member from Godot's bundle."""

    selected = dict(spec or ANDROID_SOURCE_TEMPLATE)
    values = os.environ if environ is None else environ
    root = (cache_root or android_template_cache_root(values)).expanduser().resolve()
    root.mkdir(parents=True, exist_ok=True)
    with _CacheLock(root):
        _cleanup_cache_orphans(root)
        version_root = root / GODOT_VERSION
        cached = _cached_android_source(version_root, selected)
        if cached is not None:
            os.utime(version_root)
            _prune_version_cache(root, GODOT_VERSION)
            return cached
        if version_root.exists():
            if version_root.is_symlink() or not version_root.is_dir():
                raise RuntimeError(
                    f"Android template cache entry has an invalid type: {version_root}"
                )
            shutil.rmtree(version_root)

        explicit = values.get("ASTROTOPS_ANDROID_SOURCE_TEMPLATE")
        candidates = (
            list(installed_candidates)
            if installed_candidates is not None
            else _installed_android_source_candidates(values)
        )
        if explicit:
            explicit_path = pathlib.Path(explicit).expanduser().resolve(strict=True)
            if not _matches_pinned_file(explicit_path, selected):
                raise RuntimeError(
                    "ASTROTOPS_ANDROID_SOURCE_TEMPLATE does not match the pinned "
                    f"Godot {GODOT_VERSION} Android source template."
                )
            candidates.insert(0, explicit_path)

        extraction_root = pathlib.Path(tempfile.mkdtemp(prefix=".extract-", dir=root))
        download_path = root / f".download-{os.getpid()}-{time.time_ns()}.zip"
        try:
            filename = selected.get("filename")
            url = selected.get("url")
            member = selected.get("member")
            if not all(isinstance(item, str) for item in (filename, url, member)):
                raise RuntimeError("Pinned Android source metadata is invalid.")
            destination = extraction_root / str(filename)
            local_source = next(
                (candidate for candidate in candidates if _matches_pinned_file(candidate, selected)),
                None,
            )
            if local_source is not None:
                shutil.copyfile(local_source, destination)
            else:
                download(str(url), str(member), download_path)
                if not _matches_pinned_file(download_path, selected):
                    raise RuntimeError(
                        "Android source template integrity check failed: "
                        f"size={download_path.stat().st_size}/{selected.get('size')}, "
                        f"sha256={_sha256(download_path)}/{selected.get('sha256')}."
                    )
                os.replace(download_path, destination)
            manifest = {
                "schema": ANDROID_TEMPLATE_CACHE_SCHEMA,
                "version": GODOT_TEMPLATE_IDENTIFIER,
                "member": member,
                "sha256": selected["sha256"],
                "size": selected["size"],
            }
            (extraction_root / "manifest.json").write_text(
                json.dumps(manifest, indent=2, sort_keys=True) + "\n",
                encoding="utf-8",
                newline="\n",
            )
            os.replace(extraction_root, version_root)
        except (OSError, RuntimeError, zipfile.BadZipFile, KeyError) as error:
            raise RuntimeError(
                "Automatic Android source-template provisioning failed in "
                f"{root}: {error}"
            ) from error
        finally:
            download_path.unlink(missing_ok=True)
            if extraction_root.exists():
                shutil.rmtree(extraction_root)
        cached = _cached_android_source(version_root, selected)
        if cached is None:
            raise RuntimeError(
                "Provisioned Android source-template cache failed final verification."
            )
        _prune_version_cache(root, GODOT_VERSION)
        return cached


def android_build_template_ready(repo_root: pathlib.Path) -> bool:
    android_root = repo_root / "android"
    version_path = android_root / ".build_version"
    try:
        version = version_path.read_text(encoding="utf-8").strip()
    except OSError:
        return False
    return version == GODOT_TEMPLATE_IDENTIFIER and (
        android_root / "build" / "build.gradle"
    ).is_file()


def _safe_extract_android_source(
    source_archive: pathlib.Path,
    build_root: pathlib.Path,
) -> None:
    with zipfile.ZipFile(source_archive) as archive:
        for info in archive.infolist():
            if "\\" in info.filename:
                raise RuntimeError(
                    f"Android source template contains an unsafe path: {info.filename}"
                )
            relative = pathlib.PurePosixPath(info.filename)
            if relative.is_absolute() or ".." in relative.parts:
                raise RuntimeError(
                    f"Android source template contains an unsafe path: {info.filename}"
                )
            mode = info.external_attr >> 16
            if stat.S_ISLNK(mode):
                raise RuntimeError(
                    f"Android source template contains a symbolic link: {info.filename}"
                )
            target = build_root.joinpath(*relative.parts)
            try:
                target.resolve().relative_to(build_root.resolve())
            except ValueError as error:
                raise RuntimeError(
                    f"Android source template escapes its build root: {info.filename}"
                ) from error
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            target.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(info) as source, target.open("wb") as output:
                shutil.copyfileobj(source, output, length=1024 * 1024)
            if platform.system().lower() != "windows" and mode:
                target.chmod(mode & 0o777)


def _cleanup_project_template_orphans(repo_root: pathlib.Path) -> None:
    """Remove only interrupted staging directories owned by this helper."""

    for child in repo_root.iterdir():
        if not (
            child.name.startswith(".astrotops-android-template-")
            and child.name.endswith(".tmp")
        ):
            continue
        if child.is_dir() and not child.is_symlink():
            shutil.rmtree(child)
        else:
            child.unlink()


def install_android_build_template(
    repo_root: pathlib.Path,
    source_archive: pathlib.Path,
) -> pathlib.Path:
    """Install one missing project template without overwriting local work."""

    root = repo_root.expanduser().resolve(strict=True)
    with _CacheLock(root, ".astrotops-android-template.lock.tmp"):
        _cleanup_project_template_orphans(root)
        if android_build_template_ready(root):
            return root / "android" / "build"
        android_root = root / "android"
        if android_root.exists():
            raise RuntimeError(
                "The existing Android build-template directory is incomplete or is not "
                f"for Godot {GODOT_TEMPLATE_IDENTIFIER}: {android_root}. It was preserved."
            )
        staging = (
            root
            / f".astrotops-android-template-{os.getpid()}-{time.time_ns()}.tmp"
        )
        try:
            build_root = staging / "build"
            build_root.mkdir(parents=True)
            _safe_extract_android_source(source_archive, build_root)
            (staging / ".build_version").write_text(
                GODOT_TEMPLATE_IDENTIFIER + "\n", encoding="utf-8", newline="\n"
            )
            (staging / ".astrotops-template.json").write_text(
                json.dumps(
                    {
                        "schema": ANDROID_PROJECT_TEMPLATE_SCHEMA,
                        "version": GODOT_TEMPLATE_IDENTIFIER,
                        "sourceSha256": _sha256(source_archive),
                    },
                    indent=2,
                    sort_keys=True,
                )
                + "\n",
                encoding="utf-8",
                newline="\n",
            )
            (build_root / ".gdignore").write_text(
                "\n", encoding="utf-8", newline="\n"
            )
            if not (build_root / "build.gradle").is_file():
                raise RuntimeError("Android source template has no build.gradle.")
            os.replace(staging, android_root)
        except (OSError, RuntimeError, zipfile.BadZipFile) as error:
            raise RuntimeError(
                f"Android project-template installation failed: {error}"
            ) from error
        finally:
            if staging.exists():
                shutil.rmtree(staging)
        return android_root / "build"


def ensure_android_build_template(
    repo_root: pathlib.Path,
    *,
    template_provider: Callable[[], pathlib.Path] = provision_android_source_template,
) -> pathlib.Path:
    root = repo_root.expanduser().resolve(strict=True)
    if android_build_template_ready(root):
        with _CacheLock(root, ".astrotops-android-template.lock.tmp"):
            _cleanup_project_template_orphans(root)
            if android_build_template_ready(root):
                return root / "android" / "build"
    return install_android_build_template(root, template_provider())


def bootstrap_godot_imports(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
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
    template_provider: Callable[[], pathlib.Path] = provision_android_source_template,
) -> pathlib.Path:
    """Install prerequisites and create one fresh Android debug artifact."""

    resolved = (
        output.expanduser().resolve()
        if output.is_absolute()
        else (repo_root / output).resolve()
    )
    try:
        resolved.relative_to(repo_root)
    except ValueError as error:
        raise RuntimeError(f"Godot export must stay inside {repo_root}: {resolved}") from error
    ensure_android_build_template(repo_root, template_provider=template_provider)
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


def _android_build_environment(
    environ: Mapping[str, str] | None = None,
) -> dict[str, str]:
    """Return an Android build environment or fail before an expensive export."""

    environment = dict(os.environ if environ is None else environ)
    java_home_value = environment.get("JAVA_HOME", "").strip().strip('"')
    java_home = pathlib.Path(java_home_value).expanduser() if java_home_value else None
    java_names = ("java.exe", "java") if os.name == "nt" else ("java", "java.exe")
    java_from_home = bool(
        java_home
        and any((java_home / "bin" / name).is_file() for name in java_names)
    )
    if not java_from_home and shutil.which("java", path=environment.get("PATH")) is None:
        raise RuntimeError(
            "Android validation requires a JDK: set JAVA_HOME to a JDK or add java to PATH."
        )

    sdk_value = (
        environment.get("ANDROID_HOME", "").strip().strip('"')
        or environment.get("ANDROID_SDK_ROOT", "").strip().strip('"')
    )
    sdk_root = pathlib.Path(sdk_value).expanduser() if sdk_value else None
    if not sdk_root or not sdk_root.is_dir():
        raise RuntimeError(
            "Android validation requires an SDK: set ANDROID_HOME or ANDROID_SDK_ROOT."
        )
    missing = [
        name for name in ("build-tools", "platforms") if not (sdk_root / name).is_dir()
    ]
    if missing:
        raise RuntimeError(
            f"Android SDK at {sdk_root} is missing required directories: {', '.join(missing)}"
        )
    return environment


def validate_android_build(
    repo_root: pathlib.Path,
    godot: pathlib.Path,
    *,
    run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run,
    template_provider: Callable[[], pathlib.Path] = provision_android_source_template,
    environ: Mapping[str, str] | None = None,
) -> None:
    """Parse, export, and lint Android while cleaning the validation-only APK."""

    root = repo_root.expanduser().resolve(strict=True)
    environment = _android_build_environment(environ)
    validation_directory = root / ".build" / "artifacts" / "android" / ".validation"
    validation_apk = validation_directory / "AstroTops.apk"
    try:
        validate_godot_project(root, godot, run=run)
        export_debug_project(
            root,
            godot,
            validation_apk,
            run=run,
            template_provider=template_provider,
        )
        wrapper_name = "gradlew.bat" if os.name == "nt" else "gradlew"
        wrapper = root / "android" / "build" / wrapper_name
        if not wrapper.is_file():
            raise RuntimeError(f"Android source template has no Gradle wrapper: {wrapper}")
        if os.name == "nt":
            command = [
                environment.get("COMSPEC") or "cmd.exe",
                "/d",
                "/s",
                "/c",
                str(wrapper),
                "lint",
                "--no-daemon",
                "--console=plain",
            ]
        else:
            command = [
                shutil.which("sh", path=environment.get("PATH")) or "/bin/sh",
                str(wrapper),
                "lint",
                "--no-daemon",
                "--console=plain",
            ]
        completed = run(
            command,
            cwd=wrapper.parent,
            env=environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            timeout=900,
        )
        if completed.returncode:
            detail = (completed.stderr or completed.stdout).strip()
            raise RuntimeError(
                f"Android Gradle lint failed ({completed.returncode}): {detail[-2000:]}"
            )
    finally:
        validation_apk.unlink(missing_ok=True)
        if validation_directory.is_dir() and not any(validation_directory.iterdir()):
            validation_directory.rmdir()
