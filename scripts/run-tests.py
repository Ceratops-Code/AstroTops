#!/usr/bin/env python3
"""Run, reuse, and record grouped AstroTops gameplay regressions.

The feature inventory owns group coverage and source-file ownership. Each group
runs in an isolated temporary directory; rendered tests use a real Godot OpenGL
window (under Xvfb on Linux). The runner atomically updates the affected group,
preserves only still-applicable passing groups, recalculates the overall result,
and leaves compact assertion differences in both the console and bounded
``.test-results/evidence`` logs.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import platform
import shutil
import subprocess
import sys
import tempfile
import time
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
    group_fingerprint,
    resolve_artifact_identity,
    resolve_source_identity,
)

INVENTORY_SCHEMA = "astrotops-test-inventory.v1"
GODOT_RESULT_PREFIX = "ASTROTOPS_TEST_RESULT="


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
        if item.get("mode") not in ("headless", "rendered"):
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


def resolve_godot(requested: pathlib.Path | None) -> pathlib.Path:
    """Resolve the caller-selected or PATH-owned Godot executable."""

    if requested is not None:
        return requested.expanduser().resolve(strict=True)
    configured = os.environ.get("GODOT_EXECUTABLE")
    if configured:
        return pathlib.Path(configured).expanduser().resolve(strict=True)
    discovered = shutil.which("godot") or shutil.which("godot.exe")
    if not discovered:
        raise RuntimeError("Godot is unavailable; pass --godot or set GODOT_EXECUTABLE.")
    return pathlib.Path(discovered).resolve(strict=True)


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
        if not isinstance(validation_source, dict) or (
            validation_source.get("commit") != source_identity.commit
            or validation_source.get("digest") != source_identity.digest
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
    parser.add_argument(
        "--verify-delivery",
        action="store_true",
        help="Verify retained results and exact artifact bytes without executing tests.",
    )
    parser.add_argument("--source-tag")
    parser.add_argument("--artifact", type=pathlib.Path)
    args = parser.parse_args()

    repo_root = args.repo_root.expanduser().resolve(strict=True)
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

    started = time.time()
    timestamp = datetime.now(UTC).strftime("%Y%m%dT%H%M%SZ")
    run_id = f"{timestamp}-{source_identity.commit[:12]}"
    evidence_root = store.begin_evidence_run(run_id)
    selected = set(args.group or group_ids)
    explicit_selection = bool(args.group)
    source = source_identity.portable()
    artifact = artifact_identity.portable() if artifact_identity else None
    file_owners = inventory["fileOwners"]
    if not isinstance(file_owners, dict):
        print("The test inventory has no valid file ownership map.", file=sys.stderr)
        return 1
    results: list[dict[str, object]] = []

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
