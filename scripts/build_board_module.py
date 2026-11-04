#!/usr/bin/env python3
"""Build the standalone BoBo Android libraries or run their JVM behavior tests.

The module owns native/.gradle and native/.build as disposable Gradle caches.
This helper owns addons/bobo_board/.artifacts: one current AAR per library and
variant, plus one bounded last-build log. Startup and successful publication
remove only its exact temporary siblings; no host APK or unrelated output is
touched. A failed build removes stale public AARs so export cannot package them.
"""
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from collections.abc import Callable
from pathlib import Path

ARTIFACT_NAMES = tuple(f"{module}-{variant}.aar" for module in ("board", "godot") for variant in ("debug", "release"))
LOG_LIMIT = 2 * 1024 * 1024


def build_board_module(repo_root: Path, *, tests: bool = False, run: Callable[..., subprocess.CompletedProcess[str]] = subprocess.run) -> dict[str, object]:
    """Run Gradle from the reusable module, preserving both process output streams."""
    module = repo_root / "addons" / "bobo_board"
    native = module / "native"
    output = module / ".artifacts"
    output.mkdir(parents=True, exist_ok=True)
    for name in ARTIFACT_NAMES:
        (output / ("." + name + ".tmp")).unlink(missing_ok=True)
    wrapper = native / ("gradlew.bat" if os.name == "nt" else "gradlew")
    tasks = [":board:testDebugUnitTest"] if tests else [":board:assembleDebug", ":board:assembleRelease", ":godot:assembleDebug", ":godot:assembleRelease"]
    command = [str(wrapper), "--no-daemon", "--console=plain", *tasks]
    try:
        completed = run(command, cwd=native, capture_output=True, text=True, encoding="utf-8", errors="replace", check=False, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        stdout = getattr(error, "stdout", None) or ""
        stderr = getattr(error, "stderr", None) or ""
        if isinstance(stdout, bytes):
            stdout = stdout.decode("utf-8", errors="replace")
        if isinstance(stderr, bytes):
            stderr = stderr.decode("utf-8", errors="replace")
        completed = subprocess.CompletedProcess(command, 124 if isinstance(error, subprocess.TimeoutExpired) else 127, stdout, stderr + "\n" + str(error))
    diagnostic = "\n".join((
        "operation: " + ("test BoBo module" if tests else "build BoBo module"),
        "target: addons/bobo_board/native",
        "invocation: " + json.dumps(command),
        "exit_status: " + str(completed.returncode),
        "stdout:\n" + (completed.stdout or "<absent>"),
        "stderr:\n" + (completed.stderr or "<absent>"),
    ))
    raw = diagnostic.encode("utf-8")
    if len(raw) > LOG_LIMIT:
        raw = b"<earlier output omitted under the 2 MiB retention limit>\n" + raw[-LOG_LIMIT:]
    log = output / "build.log"
    log.write_bytes(raw)
    if completed.returncode:
        if not tests:
            for name in ARTIFACT_NAMES:
                (output / name).unlink(missing_ok=True)
        raise RuntimeError("BoBo module operation failed; " + str(log) + "\n" + diagnostic[-6000:])
    if tests:
        reports = list((native / ".build" / "board" / "test-results" / "testDebugUnitTest").glob("TEST-*.xml"))
        if not reports:
            raise RuntimeError("BoBo module tests returned success without JUnit reports: " + str(log))
        checks = []
        for report in reports:
            suite = ET.parse(report).getroot()
            for case in suite.findall("testcase"):
                if case.find("failure") is not None or case.find("error") is not None:
                    raise RuntimeError("BoBo module JUnit failure: " + str(report))
                checks.append(str(case.get("classname")) + "/" + str(case.get("name")))
        if not checks:
            raise RuntimeError("BoBo module test reports contained no behavior checks.")
        return {"checks": checks}
    sources = {
        name: native / ".build" / name.split("-")[0] / "outputs" / "aar" / name
        for name in ARTIFACT_NAMES
    }
    for source in sources.values():
        if not source.is_file() or source.stat().st_size == 0:
            for name in ARTIFACT_NAMES:
                (output / name).unlink(missing_ok=True)
            raise RuntimeError("BoBo module did not produce " + str(source))
    try:
        for name, source in sources.items():
            temporary = output / ("." + name + ".tmp")
            shutil.copyfile(source, temporary)
            temporary.replace(output / name)
    except OSError as error:
        for name in ARTIFACT_NAMES:
            (output / name).unlink(missing_ok=True)
            (output / ("." + name + ".tmp")).unlink(missing_ok=True)
        raise RuntimeError("BoBo module AAR publication failed at " + str(output) + ": " + str(error)) from error
    return {"artifacts": [str(output / name) for name in ARTIFACT_NAMES]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--test", action="store_true")
    args = parser.parse_args()
    try:
        build_board_module(Path(__file__).resolve().parent.parent, tests=args.test)
    except (RuntimeError, OSError) as error:
        print(str(error), file=sys.stderr)
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
