#!/usr/bin/env python3
"""Check repository layout, export paths, acceptance data, and ignore rules."""

from __future__ import annotations

import configparser
import json
import pathlib
import subprocess
import sys


def repository_contract(repo_root: pathlib.Path) -> list[str]:
    """Validate the portable layout and structured acceptance contract."""

    problems: list[str] = []
    required = (
        ".build/README.md",
        "docs/feature-acceptance.json",
        "scripts/regression_tests.gd",
        "scripts/result_records.py",
        "scripts/run-tests.py",
    )
    for relative in required:
        if not (repo_root / relative).is_file():
            problems.append(f"missing={relative}")

    forbidden_root_files = (
        ".markdownlint.json",
        ".ruff.toml",
        "eslint.config.js",
        "mypy.ini",
        "package-lock.json",
        "package.json",
        "project.toml",
        "pyproject.toml",
        "ruff.toml",
        "uv.lock",
    )
    for name in forbidden_root_files:
        if (repo_root / name).exists():
            problems.append(f"root-tooling-file={name}")

    presets = configparser.ConfigParser(interpolation=None, strict=True)
    try:
        presets.read(repo_root / "export_presets.cfg", encoding="utf-8")
        expected_exports = {
            "preset.0": ".build/artifacts/windows/AstroTops.exe",
            "preset.1": ".build/artifacts/android/AstroTops.apk",
        }
        for section, expected in expected_exports.items():
            actual = presets.get(section, "export_path", fallback="").strip('"')
            if actual != expected:
                problems.append(
                    f"{section}.export_path expected={expected} actual={actual}"
                )
    except (OSError, configparser.Error) as error:
        problems.append(f"export-presets={error}")

    try:
        feature_map = json.loads(
            (repo_root / "docs" / "feature-acceptance.json").read_text(
                encoding="utf-8"
            )
        )
        inventory = feature_map.get("testInventory")
        requirements = feature_map.get("requirements")
        if feature_map.get("schema") != "astrotops-feature-acceptance.v1":
            problems.append("feature-map-schema=unsupported")
        if not isinstance(inventory, dict) or not inventory.get("groups"):
            problems.append("feature-map-inventory=missing")
        if not isinstance(requirements, list) or not requirements:
            problems.append("feature-map-requirements=missing")
    except (OSError, json.JSONDecodeError) as error:
        problems.append(f"feature-map={error}")

    ignored_probes = (
        ".build/artifacts/probe.apk",
        ".godot/probe",
        ".test-results/evidence/probe.log",
        "android/probe",
        "scripts/.venv/probe",
        "scripts/__pycache__/probe.pyc",
        "scripts/node_modules/probe",
    )
    tracked_probes = (
        ".build/README.md",
        ".test-results/tests.json",
        ".test-results/validation.json",
    )
    for relative in ignored_probes:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "check-ignore", "--no-index", "--quiet", relative],
            check=False,
        )
        if result.returncode != 0:
            problems.append(f"not-ignored={relative}")
    for relative in tracked_probes:
        result = subprocess.run(
            ["git", "-C", str(repo_root), "check-ignore", "--no-index", "--quiet", relative],
            check=False,
        )
        if result.returncode == 0:
            problems.append(f"unexpectedly-ignored={relative}")
    return problems


def main() -> int:
    errors = repository_contract(pathlib.Path(__file__).resolve().parents[1])
    for error in errors:
        print(error, file=sys.stderr)
    if errors:
        return 1
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
