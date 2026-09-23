# Contributing

Contributions should keep PlaneTops simple, responsive, and usable with a
keyboard, gamepad, or touch input.

## Rules

- Keep gameplay compatible with Godot 4.7.2 and the GL Compatibility renderer.
- Preserve the compressed Solar System size hierarchy and recognizable planet
  designs.
- Keep keyboard, gamepad, and touch behavior aligned when changing controls.
- Do not commit generated `.godot`, `android`, or `build` directories.
- Do not commit signing keys, credentials, or user-specific absolute paths.
- Record the source and license of every third-party asset.

## Validation

Before opening a pull request, run:

```powershell
npm --prefix scripts ci
uv sync --project scripts --locked
uv run --locked scripts/validate-repository.py
```

Also open the project in Godot 4.7.2, verify that it parses without errors, and
exercise the changed gameplay with every affected input method.
