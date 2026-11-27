# Build records

The Android package build exports `AstroTops-<version>.apk` into the attempt directory
Ceratops supplies as `{artifact_directory}`. Godot writes the APK there directly.
After export succeeds, `scripts/result_records.py build-result` writes the relative APK
name to `{build_receipt}`. Ceratops keeps the accepted APK in Git's common
`ceratops/artifacts/` store and commits the receipt and check summary under
`.ceratops/build/`. To install that APK, request
`deliverables.packages.astrotops-android-apk.actions.install`. It passes the
accepted file to ADB and installs it if the device has different bytes.

For a standalone export, pass the desired path to `scripts/run-tests.py --export-debug`.
That command records the checkout source and the APK digest for later standalone installation.
`.ceratops/build/builds/` retains historical source-tag reports.

A candidate run made with `--source-tag` and `--artifact` can still export a
historical report. Ceratops delivery uses the accepted package and its saved SDLC check outcomes.

The check-history reader accepts current `ceratops-build-result.v4` receipts in
`.ceratops/build/members/<type>/<name>/<version>/[<target>/]` and
`.ceratops/build/bundles/<name>/<version>/[<target>/]`. It reads each receipt's tagged
`check_summary.json` for reuse, without opening packages or scanning another
checkout. Receipts in unsupported formats supply no reusable results.
