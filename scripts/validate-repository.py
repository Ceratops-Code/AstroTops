#!/usr/bin/env python3
"""Run repository validation, excluding tests, in the scripts project's uv environment.

SDLC invokes this script with the locked project under scripts.
uv owns dependency synchronization; this entrypoint never installs
dependencies or runs test suites. Failed-check evidence survives for diagnosis
and is removed after success. Test commands belong in SDLC tests operations.
"""

from __future__ import annotations

import argparse
import configparser
import json
import os
import pathlib
import platform
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime

_SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
if str(_SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(_SCRIPT_DIRECTORY))

from result_records import (  # noqa: E402
    VALIDATION_SCHEMA,
    ResultStore,
    SourceIdentity,
    resolve_source_identity,
)

CHECK_DEFINITIONS = [{'id': 'repository-contract',
  'command': ['{python}', 'scripts/validate-repository.py', '--contract-only'],
  'cwd': '.',
  'exclusive': False},
 {'id': 'npm-markdown-lint',
  'command': ['{npm}', '--prefix', 'scripts', 'run', 'lint:markdown'],
  'cwd': '.',
  'exclusive': False},
 {'id': 'ruff',
  'command': ['{python}',
              '-m',
              'ruff',
              'check',
              '.',
              '--config',
              'scripts/pyproject.toml'],
  'cwd': '.',
  'exclusive': False},
 {'id': 'mypy',
  'command': ['{python}',
              '-m',
              'mypy',
              '--config-file',
              'scripts/pyproject.toml'],
  'cwd': '.',
  'exclusive': False},
 {'id': 'actionlint',
  'command': ['{python}', 'scripts/run-actionlint.py'],
  'cwd': '.',
  'exclusive': False}]
COMMAND_NOT_FOUND_EXIT_CODE = 127


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


def command(definition: dict[str, object], temporary_root: pathlib.Path) -> list[str]:
    """Resolve portable executable tokens without shell parsing."""

    npm = "npm.cmd" if sys.platform == "win32" else "npm"
    pnpm = "pnpm.cmd" if sys.platform == "win32" else "pnpm"
    pwsh = "pwsh.exe" if sys.platform == "win32" else "pwsh"
    values = {
        "{python}": sys.executable,
        "{npm}": npm,
        "{pnpm}": pnpm,
        "{pwsh}": pwsh,
        "{temp}": str(temporary_root),
    }
    raw_command = definition["command"]
    if not isinstance(raw_command, list):
        raise TypeError("check command must be a list")
    resolved: list[str] = []
    for raw in raw_command:
        value = str(raw)
        for token, replacement in values.items():
            value = value.replace(token, replacement)
        resolved.append(value)
    return resolved


def prepare_temporary_directories(
    argv: list[str], temporary_root: pathlib.Path
) -> None:
    """Create only contract-declared working directories inside the owned root."""

    resolved_root = temporary_root.resolve()
    for index, value in enumerate(argv[:-1]):
        if value != "--temp-root":
            continue
        path = pathlib.Path(argv[index + 1]).resolve()
        try:
            path.relative_to(resolved_root)
        except ValueError:
            continue
        path.mkdir(parents=True, exist_ok=True)


def cleanup_evidence(
    evidence_file: pathlib.Path,
    *,
    prune_default_parent: bool,
) -> None:
    """Remove stale failure evidence after success and only its owned directory."""

    evidence_file.unlink(missing_ok=True)
    evidence_file.with_name(f".{evidence_file.name}.tmp").unlink(missing_ok=True)
    if prune_default_parent:
        try:
            evidence_file.parent.rmdir()
        except FileNotFoundError:
            pass
        except OSError:
            if not evidence_file.parent.is_dir() or any(
                evidence_file.parent.iterdir()
            ):
                return
            raise


def child_evidence(argv: list[str], temporary_root: pathlib.Path) -> list[str]:
    """Retain declared child-validator evidence before temporary cleanup."""

    paths: list[pathlib.Path] = []
    for index, value in enumerate(argv):
        if value == "--evidence-file" and index + 1 < len(argv):
            paths.append(pathlib.Path(argv[index + 1]))
        elif value.startswith("--evidence-file="):
            paths.append(pathlib.Path(value.partition("=")[2]))
    retained: list[str] = []
    temporary_root = temporary_root.resolve()
    for path in paths:
        resolved = path.resolve()
        try:
            resolved.relative_to(temporary_root)
        except ValueError:
            continue
        if resolved.is_symlink() or not resolved.is_file():
            continue
        retained.extend(
            (
                f"child_evidence: {resolved.relative_to(temporary_root).as_posix()}",
                resolved.read_text(encoding="utf-8", errors="replace"),
            )
        )
    return retained


def portable_command(
    argv: list[str], repo_root: pathlib.Path, temporary_root: pathlib.Path
) -> list[str]:
    """Remove host-specific executable and temporary paths from tracked JSON."""

    rendered: list[str] = []
    for value in argv:
        if value == sys.executable:
            rendered.append("{python}")
        elif value == str(repo_root):
            rendered.append("{repo}")
        elif value == str(temporary_root):
            rendered.append("{temp}")
        elif value.startswith(str(temporary_root) + os.sep):
            suffix = pathlib.Path(value).relative_to(temporary_root).as_posix()
            rendered.append(f"{{temp}}/{suffix}")
        else:
            rendered.append(value)
    return rendered


def portable_evidence(evidence_file: pathlib.Path, repo_root: pathlib.Path) -> str:
    """Return a repository-relative evidence location without leaking host paths."""

    try:
        return evidence_file.resolve().relative_to(repo_root).as_posix()
    except ValueError:
        return "{caller-selected-evidence}"


def validation_environment() -> dict[str, str]:
    """Describe the execution context that determines result applicability."""

    return {
        "machine": platform.machine(),
        "platform": sys.platform,
        "python": platform.python_version(),
    }


def applicable_validation_exists(
    path: pathlib.Path,
    source: SourceIdentity,
    environment: dict[str, str],
    required_checks: list[str],
) -> bool:
    """Avoid result churn when an equivalent passing record already exists."""

    try:
        previous = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    previous_source = previous.get("source")
    previous_results = previous.get("results")
    if not isinstance(previous_source, dict) or not isinstance(previous_results, list):
        return False
    result_ids = [
        item.get("id") for item in previous_results if isinstance(item, dict)
    ]
    return (
        previous.get("schema") == VALIDATION_SCHEMA
        and previous.get("status") == "passed"
        and previous.get("outcome") == "passed"
        and previous_source.get("commit") == source.commit
        and previous_source.get("digest") == source.digest
        and previous.get("environment") == environment
        and previous.get("requiredChecks") == required_checks
        and result_ids == required_checks
        and all(
            isinstance(item, dict) and item.get("outcome") == "passed"
            for item in previous_results
        )
    )


def validation_record(
    *,
    source: SourceIdentity,
    environment: dict[str, str],
    required_checks: list[str],
    results: list[dict[str, object]],
    outcome: str,
    failures: list[dict[str, object]],
    evidence: str | None,
    run_id: str,
) -> dict[str, object]:
    """Assemble the portable latest validation result."""

    return {
        "schema": VALIDATION_SCHEMA,
        "status": outcome,
        "outcome": outcome,
        "scope": "repository",
        "source": source.portable(),
        "environment": environment,
        "requiredChecks": required_checks,
        "results": results,
        "failures": failures,
        "evidence": [evidence] if evidence else [],
        "runId": run_id,
        "finishedAt": datetime.now(UTC).isoformat(),
    }


def main() -> int:
    """Run contract-selected checks in order and emit one bounded result."""

    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-file", type=pathlib.Path)
    parser.add_argument("--contract-only", action="store_true")
    parser.add_argument(
        "--no-record",
        action="store_true",
        help="Run validation without replacing .test-results/validation.json.",
    )
    args = parser.parse_args()
    repo_root = pathlib.Path(__file__).resolve().parents[1]
    if args.contract_only:
        problems = repository_contract(repo_root)
        if problems:
            print("\n".join(problems))
            return 1
        print("OK")
        return 0
    evidence_file = (
        args.evidence_file.expanduser().resolve()
        if args.evidence_file
        else repo_root / ".test-results" / "evidence" / "validation" / "repository-validation.log"
    )
    source = resolve_source_identity(repo_root)
    record = not args.no_record and not source.dirty_paths
    store = ResultStore(repo_root, source, record=record)
    environment = validation_environment()
    required_checks = [str(item["id"]) for item in CHECK_DEFINITIONS]
    results: list[dict[str, object]] = []
    run_id = datetime.now(UTC).strftime("%Y%m%dT%H%M%S.%fZ")
    with tempfile.TemporaryDirectory(prefix="repository-validation-") as temporary:
        temporary_root = pathlib.Path(temporary)
        child_environment = os.environ.copy()
        child_environment["PYTHONPYCACHEPREFIX"] = str(temporary_root / "python-cache")
        for definition in CHECK_DEFINITIONS:
            argv = command(definition, temporary_root)
            prepare_temporary_directories(argv, temporary_root)
            raw_cwd = definition["cwd"]
            if not isinstance(raw_cwd, str):
                raise TypeError("check cwd must be a string")
            cwd = repo_root.joinpath(*pathlib.PurePosixPath(raw_cwd).parts)
            started = time.perf_counter()
            try:
                result = subprocess.run(
                    argv,
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    encoding="utf-8",
                    errors="replace",
                    check=False,
                    env=child_environment,
                )
            except OSError as exc:
                result = subprocess.CompletedProcess(
                    argv,
                    COMMAND_NOT_FOUND_EXIT_CODE,
                    "",
                    f"{type(exc).__name__}: {exc}",
                )
            elapsed = round(time.perf_counter() - started, 3)
            results.append(
                {
                    "id": str(definition["id"]),
                    "status": "passed" if result.returncode == 0 else "failed",
                    "outcome": "passed" if result.returncode == 0 else "failed",
                    "execution": "executed",
                    "exitCode": result.returncode,
                    "seconds": elapsed,
                    "command": portable_command(argv, repo_root, temporary_root),
                    "cwd": raw_cwd,
                }
            )
            if result.returncode == 0:
                continue
            evidence_file.parent.mkdir(parents=True, exist_ok=True)
            partial = evidence_file.with_name(f".{evidence_file.name}.tmp")
            retained_child_evidence = child_evidence(argv, temporary_root)
            partial.write_text(
                "\n".join(
                    (
                        f"check: {definition['id']}",
                        f"exit_code: {result.returncode}",
                        f"cwd: {cwd}",
                        "command: " + json.dumps(argv, separators=(",", ":")),
                        "stdout:",
                        result.stdout or "",
                        "stderr:",
                        result.stderr or "",
                        *retained_child_evidence,
                    )
                )
                + "\n",
                encoding="utf-8",
                newline="\n",
            )
            partial.replace(evidence_file)
            failure = {
                "id": f"validation/{definition['id']}",
                "expected": 0,
                "actual": result.returncode,
            }
            if record:
                store.write_validation(
                    validation_record(
                        source=source,
                        environment=environment,
                        required_checks=required_checks,
                        results=results,
                        outcome="failed",
                        failures=[failure],
                        evidence=portable_evidence(evidence_file, repo_root),
                        run_id=run_id,
                    )
                )
            print(
                f"{failure['id']} expected={failure['expected']} "
                f"actual={failure['actual']} "
                f"evidence={portable_evidence(evidence_file, repo_root)}"
            )
            return result.returncode if result.returncode > 0 else 1
    try:
        cleanup_evidence(
            evidence_file,
            prune_default_parent=args.evidence_file is None,
        )
    except OSError as exc:
        failure = {
            "id": "validation/evidence-cleanup",
            "expected": "owned evidence removed",
            "actual": f"{type(exc).__name__}: {exc}",
        }
        results.append(
            {
                "id": "evidence-cleanup",
                "status": "failed",
                "outcome": "failed",
                "execution": "executed",
                "exitCode": 1,
                "seconds": 0.0,
                "command": [],
                "cwd": ".",
            }
        )
        if record:
            store.write_validation(
                validation_record(
                    source=source,
                    environment=environment,
                    required_checks=required_checks,
                    results=results,
                    outcome="failed",
                    failures=[failure],
                    evidence=portable_evidence(evidence_file, repo_root),
                    run_id=run_id,
                )
            )
        print(
            f"{failure['id']} expected={failure['expected']} "
            f"actual={failure['actual']}"
        )
        return 1
    if record and not applicable_validation_exists(
        store.result_root / "validation.json",
        source,
        environment,
        required_checks,
    ):
        store.write_validation(
            validation_record(
                source=source,
                environment=environment,
                required_checks=required_checks,
                results=results,
                outcome="passed",
                failures=[],
                evidence=None,
                run_id=run_id,
            )
        )
    print("OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
