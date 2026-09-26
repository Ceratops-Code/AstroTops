# Contributing

Contributions should keep AstroTops simple, responsive, and usable with a
keyboard, gamepad, or touch input.

## Rules

- Keep gameplay compatible with Godot 4.7.2 and the GL Compatibility renderer.
- Preserve the compressed celestial-target size hierarchy and recognizable
  planet designs.
- Keep keyboard, gamepad, and touch behavior aligned when changing controls.
- Do not commit generated `.godot`, `android`, `.build/artifacts`, or
  `.test-results/evidence` directories.
- Do not commit signing keys, credentials, or user-specific absolute paths.
- Record the source and license of every third-party asset.
- Keep Python and Node tooling under `scripts`; do not add package, lock, lint,
  or Python-project files to the repository root.

## Validation

Before opening a pull request, run:

```powershell
npm --prefix scripts ci
uv sync --project scripts --locked
uv run --locked scripts/validate-repository.py
uv run --locked scripts/run-tests.py --fresh
```

Godot 4.7.2 must be on `PATH`, or supplied with `--godot`. Use
`--group <group-id>` after a focused change. The runner executes affected
groups in isolated settings directories, captures rendered evidence where
required, updates their tracked JSON, preserves still-applicable results, and
recalculates the repository outcome.

## Results and delivery

`.test-results/` contains the latest tracked validation and test records.
`.test-results/evidence/` contains ignored, bounded screenshots and logs for
those records. `.build/artifacts/` contains ignored packages, while
`.build/builds/` contains tracked package identity and approval metadata. The
runner retains the current evidence run and at most two predecessors.

Candidate qualification supplies both an immutable source tag and a package:

```powershell
uv run --locked scripts/run-tests.py --fresh --source-tag <tag> --artifact .build/artifacts/android/AstroTops.apk
```

The tag is the build version; its resolved commit is traceability metadata.
Delivery calls the same runner with `--verify-delivery`, which validates the
saved results and exact package bytes without repeating tests. The standard uv
configuration remains `scripts/pyproject.toml`; uv requires that standard
filename, so no root `project.toml` or `pyproject.toml` is used.
