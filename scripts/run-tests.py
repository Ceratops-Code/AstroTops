#!/usr/bin/env python3
"""Run AstroTops validation, export, and grouped regressions.

``godot_toolchain`` owns the pinned editor and Android-template lifecycle.
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
import subprocess
import sys
import tempfile
import time
import zipfile
from datetime import UTC, datetime

_SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from godot_toolchain import (  # noqa: E402
    GODOT_TEMPLATE_IDENTIFIER,
    GODOT_VERSION,
    _create_cache_staging,
    _prune_version_cache,
    _sha256,
    android_build_template_ready,
    bootstrap_godot_imports,
    export_debug_project,
    godot_version,
    install_android_build_template,
    provision_android_source_template,
    provision_godot,
    resolve_godot,
    validate_android_build,
    validate_godot_project,
)
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


def load_inventory(
    repo_root: pathlib.Path,
) -> tuple[dict[str, object], list[dict[str, object]]]:
    """Load the feature map and reject missing groups or unowned test inputs."""

    path = repo_root / "docs" / "feature-acceptance.json"
    document = json.loads(path.read_text(encoding="utf-8"))
    inventory = document.get("testInventory")
    if not isinstance(inventory, dict) or inventory.get("schema") != INVENTORY_SCHEMA:
        raise ValueError(
            "docs/feature-acceptance.json has no supported test inventory."
        )
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
        if (
            not isinstance(selected, list)
            or not selected
            or not set(selected) <= declared
        ):
            raise ValueError(
                f"Inventoried source file has invalid group owners: {relative}"
            )
    covered: set[str] = set()
    for requirement in requirements:
        if not isinstance(requirement, dict) or not requirement.get("id"):
            raise ValueError("Every feature requirement needs an id.")
        selected = requirement.get("groups")
        observations = requirement.get("observations")
        if (
            not isinstance(selected, list)
            or not selected
            or not set(selected) <= declared
        ):
            raise ValueError(f"Requirement {requirement.get('id')} has invalid groups.")
        if not isinstance(observations, list) or not observations:
            raise ValueError(
                f"Requirement {requirement.get('id')} has no observable tests."
            )
        covered.update(selected)
    if covered != declared:
        raise ValueError(f"Feature coverage omits groups: {sorted(declared - covered)}")
    return inventory, validated_groups


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

    def portable(value: object) -> object:
        """Replace this isolated run's root in retained assertion evidence."""

        if isinstance(value, str):
            return value.replace(str(temporary_root), "{temp}")
        if isinstance(value, list):
            return [portable(item) for item in value]
        if isinstance(value, tuple):
            return [portable(item) for item in value]
        if isinstance(value, dict):
            return {str(key): portable(item) for key, item in value.items()}
        return value

    def check(identifier: str, expected: object, actual: object) -> None:
        nonlocal assertions
        assertions += 1
        observations.append({"id": identifier, "actual": portable(actual)})
        if actual != expected:
            failures.append(
                {
                    "id": identifier,
                    "expected": portable(expected),
                    "actual": portable(actual),
                }
            )

    class FakeAdb:
        def __init__(
            self,
            installed_hash: str | None,
            connect_output: str,
            connected_device: str | None = device,
        ) -> None:
            self.installed_hash = installed_hash
            self.connect_output = connect_output
            self.connected_device = connected_device
            self.connects = 0
            self.installs = 0
            self.launches = 0

        def __call__(self, arguments: list[str]) -> subprocess.CompletedProcess[str]:
            if arguments[1:] == ["devices"]:
                row = f"{self.connected_device}\tdevice\n" if self.connected_device else ""
                return subprocess.CompletedProcess(
                    arguments, 0, f"List of devices attached\n{row}", ""
                )
            if arguments[1:2] == ["connect"]:
                self.connects += 1
                if "connected to" in self.connect_output.lower():
                    self.connected_device = arguments[2]
                return subprocess.CompletedProcess(
                    arguments, 0, self.connect_output + "\n", ""
                )
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
            return subprocess.CompletedProcess(
                arguments, 97, "", "unexpected fake ADB command"
            )

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
    check("connected-serial-skips-connect", 0, exact.connects)
    check("exact-apk-skips-install", 0, exact.installs)
    check("exact-apk-launches", 1, exact.launches)
    check(
        "deployment-receipt-schema",
        "ceratops-deployment-result.v1",
        exact_receipt.get("schema"),
    )
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

    usb_device = "R9ZY508NZWM"
    usb = FakeAdb(expected_hash, "", connected_device=usb_device)
    usb_receipt = android_deploy_result(
        fake_repo,
        adb_executable="adb",
        device=usb_device,
        package=package,
        activity=activity,
        artifact=artifact,
        artifact_type="android-apk",
        run=usb,
    )
    check("usb-serial-skips-connect", 0, usb.connects)
    check("usb-serial-remains-target", usb_device, usb_receipt.get("target"))

    mdns_device = "adb-R9ZY508NZWM-probe._adb-tls-connect._tcp"
    mdns = FakeAdb(expected_hash, "", connected_device=mdns_device)
    mdns_receipt = android_deploy_result(
        fake_repo,
        adb_executable="adb",
        device=mdns_device,
        package=package,
        activity=activity,
        artifact=artifact,
        artifact_type="android-apk",
        run=mdns,
    )
    check("mdns-serial-skips-connect", 0, mdns.connects)
    check("mdns-serial-remains-target", mdns_device, mdns_receipt.get("target"))

    network = FakeAdb(None, f"connected to {device}", connected_device=None)
    android_deploy_result(
        fake_repo,
        adb_executable="adb",
        device=device,
        package=package,
        activity=activity,
        artifact=artifact,
        artifact_type="android-apk",
        run=network,
    )
    check("network-endpoint-connects", 1, network.connects)

    false_success = FakeAdb(
        expected_hash,
        f"cannot connect to {device}",
        connected_device=None,
    )
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
    with zipfile.ZipFile(
        fake_archive, "w", compression=zipfile.ZIP_DEFLATED
    ) as archive:
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
    fake_cache.mkdir(parents=True)
    removable_staging = _create_cache_staging(fake_cache)
    (removable_staging / "probe").write_bytes(b"probe")
    shutil.rmtree(removable_staging)
    check("godot-cache-staging-is-removable", False, removable_staging.exists())
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
    _prune_version_cache(fake_cache, GODOT_VERSION)
    retained_versions = sorted(
        path.name
        for path in fake_cache.iterdir()
        if path.is_dir() and not path.name.startswith(".")
    )
    check(
        "godot-cache-retention-is-bounded",
        ["4.6.2", "4.6.3", GODOT_VERSION],
        retained_versions,
    )

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
    prerelease = temporary_root / "godot-4.7.2-rc1"
    prerelease.write_bytes(b"prerelease-godot-runtime")

    def prerelease_version(executable: pathlib.Path) -> str:
        if executable == prerelease:
            return GODOT_VERSION + ".rc1.official"
        return fake_version(executable)

    resolved_from_prerelease = resolve_godot(
        None,
        environ={},
        which=lambda name: str(prerelease) if name == "godot" else None,
        provision=lambda: repaired,
        version_probe=prerelease_version,
    )
    check(
        "godot-prerelease-path-self-provisions",
        str(repaired),
        str(resolved_from_prerelease),
    )

    fake_android_archive = temporary_root / "android-source.zip"
    with zipfile.ZipFile(
        fake_android_archive, "w", compression=zipfile.ZIP_DEFLATED
    ) as archive:
        archive.writestr("build.gradle", b"// pinned fake Android template\n")
        archive.writestr("gradlew", b"#!/bin/sh\n")
        archive.writestr("gradlew.bat", b"@echo off\r\n")
    fake_android_spec: dict[str, object] = {
        "url": "https://example.invalid/export-templates.tpz",
        "member": "templates/android_source.zip",
        "filename": "android_source.zip",
        "sha256": _sha256(fake_android_archive),
        "size": fake_android_archive.stat().st_size,
    }
    android_download_count = 0

    def fake_android_download(
        _url: str, _member: str, destination: pathlib.Path
    ) -> None:
        nonlocal android_download_count
        android_download_count += 1
        shutil.copyfile(fake_android_archive, destination)

    fake_android_cache = temporary_root / "tool-cache" / "android-template"
    android_source = provision_android_source_template(
        cache_root=fake_android_cache,
        spec=fake_android_spec,
        environ={},
        installed_candidates=[],
        download=fake_android_download,
    )
    check("android-source-downloads-once", 1, android_download_count)
    reused_android_source = provision_android_source_template(
        cache_root=fake_android_cache,
        spec=fake_android_spec,
        environ={},
        installed_candidates=[],
        download=fake_android_download,
    )
    check("android-source-cache-is-reused", 1, android_download_count)
    check(
        "android-source-cache-path-is-stable",
        str(android_source),
        str(reused_android_source),
    )
    android_source.write_bytes(b"tampered")
    repaired_android_source = provision_android_source_template(
        cache_root=fake_android_cache,
        spec=fake_android_spec,
        environ={},
        installed_candidates=[],
        download=fake_android_download,
    )
    check("android-source-tamper-is-repaired", 2, android_download_count)

    template_repo = temporary_root / "template-repo"
    template_repo.mkdir()
    installed_template = install_android_build_template(
        template_repo, repaired_android_source
    )
    check("android-project-template-is-installed", True, installed_template.is_dir())
    check(
        "android-project-template-version",
        GODOT_TEMPLATE_IDENTIFIER,
        (template_repo / "android" / ".build_version")
        .read_text(encoding="utf-8")
        .strip(),
    )
    check(
        "android-project-template-is-reused",
        str(installed_template),
        str(install_android_build_template(template_repo, repaired_android_source)),
    )
    conflict_repo = temporary_root / "template-conflict-repo"
    (conflict_repo / "android").mkdir(parents=True)
    custom_file = conflict_repo / "android" / "custom.txt"
    custom_file.write_text("preserve me\n", encoding="utf-8", newline="\n")
    try:
        install_android_build_template(conflict_repo, repaired_android_source)
    except RuntimeError as error:
        conflict_preserved = "preserved" in str(error) and custom_file.is_file()
    else:
        conflict_preserved = False
    check("android-project-template-conflict-is-preserved", True, conflict_preserved)

    fake_java_home = temporary_root / "jdk"
    (fake_java_home / "bin").mkdir(parents=True)
    (fake_java_home / "bin" / "java").write_bytes(b"fake-java")
    (fake_java_home / "bin" / "java.exe").write_bytes(b"fake-java")
    fake_android_sdk = temporary_root / "android-sdk"
    (fake_android_sdk / "build-tools").mkdir(parents=True)
    (fake_android_sdk / "platforms").mkdir()
    fake_android_environment = {
        "ANDROID_HOME": str(fake_android_sdk),
        "COMSPEC": "cmd.exe",
        "JAVA_HOME": str(fake_java_home),
        "PATH": "",
    }
    operation_calls: list[list[str]] = []
    operation_contexts: list[dict[str, object]] = []

    def fake_godot_run(
        command: list[str], **kwargs: object
    ) -> subprocess.CompletedProcess[str]:
        operation_calls.append(command)
        operation_contexts.append(kwargs)
        if "--export-debug" in command:
            pathlib.Path(command[-1]).write_bytes(b"debug-apk")
        return subprocess.CompletedProcess(command, 0, "", "")

    operation_console = temporary_root / "Godot_test_console.exe"
    operation_console.write_bytes(b"fake-console-runtime")
    operation_worker = temporary_root / "Godot_test.exe"
    operation_worker.write_bytes(b"fake-non-console-runtime")
    validate_godot_project(fake_repo, operation_console, run=fake_godot_run)
    check(
        "godot-project-validation-command",
        [
            str(operation_worker),
            "--headless",
            "--editor",
            "--path",
            str(fake_repo),
            "--quit",
        ],
        operation_calls[0],
    )
    exported = export_debug_project(
        fake_repo,
        operation_console,
        pathlib.Path(".build/artifacts/android/provisioned.apk"),
        run=fake_godot_run,
        template_provider=lambda: repaired_android_source,
    )
    check(
        "godot-export-installs-android-template",
        True,
        android_build_template_ready(fake_repo),
    )
    check(
        "godot-export-produces-artifact",
        "debug-apk",
        exported.read_bytes().decode("ascii"),
    )
    export_index = next(
        index
        for index, command in enumerate(operation_calls)
        if "--export-debug" in command
    )
    export_call = operation_calls[export_index]
    export_context = operation_contexts[export_index]
    check(
        "godot-export-uses-non-console-worker",
        str(operation_worker),
        export_call[0],
    )
    check(
        "godot-export-uses-file-backed-capture",
        True,
        not export_context.get("capture_output", False)
        and export_context.get("stdout") not in (None, subprocess.PIPE)
        and export_context.get("stderr") not in (None, subprocess.PIPE),
    )
    validation_start = len(operation_calls)
    validate_android_build(
        fake_repo,
        repaired,
        run=fake_godot_run,
        template_provider=lambda: repaired_android_source,
        environ=fake_android_environment,
    )
    validation_calls = operation_calls[validation_start:]
    check(
        "android-validation-exports-debug-build",
        True,
        any("--export-debug" in command for command in validation_calls),
    )
    check(
        "android-validation-runs-gradle-lint",
        True,
        bool(validation_calls and "lint" in validation_calls[-1]),
    )
    check(
        "android-validation-gradle-working-directory",
        str(fake_repo / "android" / "build"),
        str(operation_contexts[-1].get("cwd")),
    )
    check(
        "android-validation-cleans-temporary-apk",
        False,
        (
            fake_repo
            / ".build"
            / "artifacts"
            / "android"
            / ".validation"
            / "AstroTops.apk"
        ).exists(),
    )
    calls_before_missing_jdk = len(operation_calls)
    try:
        validate_android_build(
            fake_repo,
            repaired,
            run=fake_godot_run,
            template_provider=lambda: repaired_android_source,
            environ={"ANDROID_HOME": str(fake_android_sdk), "PATH": ""},
        )
    except RuntimeError as error:
        missing_jdk_rejected = "requires a JDK" in str(error)
    else:
        missing_jdk_rejected = False
    check(
        "android-validation-rejects-missing-jdk-before-export",
        True,
        missing_jdk_rejected and len(operation_calls) == calls_before_missing_jdk,
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
        "evidence": [log_path.relative_to(group_evidence.parents[2]).as_posix()],
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
                    "failures": [
                        {
                            "id": "runner/xvfb",
                            "expected": "xvfb-run on PATH",
                            "actual": "missing",
                        }
                    ],
                    "observations": [],
                    "evidence": [],
                }
            command.extend([xvfb, "-a"])
        command.append(str(godot))
        if mode == "headless":
            command.append("--headless")
        else:
            command.extend(
                ["--rendering-method", "gl_compatibility", "--audio-driver", "Dummy"]
            )
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
        if not isinstance(raw_failures, list) or not all(
            isinstance(item, dict) for item in raw_failures
        ):
            raise TypeError("failures must be a list of objects")
        if not isinstance(raw_observations, list) or not all(
            isinstance(item, dict) for item in raw_observations
        ):
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
            failures.append(
                {
                    "id": "runner/group-result",
                    "expected": group_id,
                    "actual": payload.get("group"),
                }
            )
        if payload.get("status") != "passed":
            failures.append(
                {
                    "id": "runner/group-status",
                    "expected": "passed",
                    "actual": payload.get("status"),
                }
            )
    except (ValueError, TypeError, json.JSONDecodeError) as error:
        failures = [
            {
                "id": "runner/structured-result",
                "expected": "valid Godot result",
                "actual": str(error),
            }
        ]
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
        "command": portable_command(
            command, godot, repo_root, temporary, group_evidence
        ),
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
    return (
        value
        if isinstance(value, dict) and value.get("schema") == GROUP_SCHEMA
        else None
    )


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


def reused_result(
    previous: dict[str, object], source: dict[str, object]
) -> dict[str, object]:
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
        print(
            "delivery/inventory expected=file ownership map actual=missing",
            file=sys.stderr,
        )
        return 1
    artifact = artifact_identity.portable()
    failures: list[str] = []
    try:
        validation = json.loads(
            (store.result_root / "validation.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        validation = None
    if (
        not isinstance(validation, dict)
        or validation.get("schema") != VALIDATION_SCHEMA
    ):
        failures.append(
            "delivery/validation expected=valid repository result actual=missing or invalid"
        )
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
            failures.append(
                "delivery/validation expected=applicable result actual=stale"
            )
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
            failures.append(
                "delivery/validation expected=complete passing checks actual=incomplete"
            )
    group_ids: list[str] = []
    for definition in groups:
        group_id = str(definition["id"])
        group_ids.append(group_id)
        previous = load_group_result(store.group_root / f"{group_id}.json")
        if previous is None:
            failures.append(
                f"delivery/{group_id} expected=recorded pass actual=missing"
            )
            continue
        environment = previous.get("environment")
        if not isinstance(environment, dict):
            failures.append(
                f"delivery/{group_id} expected=recorded environment actual=missing"
            )
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
            failures.append(
                f"delivery/{group_id} expected=applicable result actual=stale"
            )
        elif previous.get("artifact") != artifact:
            failures.append(
                f"delivery/{group_id} expected=exact artifact actual=different"
            )

    try:
        loaded_report = json.loads(
            (store.result_root / "tests.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        loaded_report = None
    if (
        not isinstance(loaded_report, dict)
        or loaded_report.get("schema") != RESULT_SCHEMA
    ):
        failures.append(
            "delivery/report expected=valid repository result actual=missing or invalid"
        )
    else:
        if loaded_report.get("outcome") != "passed":
            failures.append(
                f"delivery/report expected=passed actual={loaded_report.get('outcome')}"
            )
        if loaded_report.get("artifact") != artifact:
            failures.append("delivery/report expected=exact artifact actual=different")
        if loaded_report.get("requiredChecks") != group_ids:
            failures.append(
                "delivery/report expected=complete group coverage actual=incomplete"
            )

    try:
        build = json.loads(
            store.build_path(artifact_identity).read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError):
        build = None
    if not isinstance(build, dict):
        failures.append(
            "delivery/build expected=tracked build metadata actual=missing or invalid"
        )
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
    parser.add_argument(
        "--repo-root", type=pathlib.Path, default=_SCRIPT_DIRECTORY.parent
    )
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
        "--validate-android-build",
        action="store_true",
        help="Parse, export, and Gradle-lint Android with explicit toolchain preflight.",
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
        args.prepare_godot
        or args.validate_project
        or args.validate_android_build
        or args.export_debug is not None
    )
    if lifecycle_mode:
        if (
            args.group
            or args.fresh
            or args.no_record
            or args.source_tag
            or args.artifact
        ):
            parser.error(
                "Godot lifecycle modes cannot be combined with test or delivery options."
            )
        try:
            godot = resolve_godot(args.godot)
            if args.validate_android_build:
                validate_android_build(repo_root, godot)
            elif args.validate_project:
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
                raise ValueError(
                    "--verify-delivery cannot be combined with execution options."
                )
            if artifact_identity is None:
                raise ValueError(
                    "--verify-delivery requires --source-tag and --artifact."
                )
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
                "failures": [
                    {
                        "id": "runner/applicability",
                        "expected": "applicable passing result",
                        "actual": "missing or stale",
                    }
                ],
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
        "execution": "reused"
        if results and all(result.get("execution") == "reused" for result in results)
        else "executed",
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
    failed = [
        str(result["id"]) for result in results if result.get("outcome") != "passed"
    ]
    print(json.dumps({"status": "failed", "groups": failed, "runId": run_id}))
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
