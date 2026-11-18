# Build records

`.build/artifacts/android/AstroTops.apk` is Godot's one current native export
for this checkout's ADB installer. Each export replaces that file. Ceratops supplies
a separate attempt directory through the build action's `artifact_directory`
parameter and owns that directory's unfinished-attempt cleanup and retention.
`.build/builds/` retains historical source-tag reports.

Successful Android export records its source digest and APK descriptor through
`scripts/result_records.py` in the shared current-results store under Git's common
directory. Its `astrotops-android-export.v1` entry is published only after export
succeeds with unchanged source. There is one current Android export per worktree,
with atomic replacement and no separate history file. Repeating identical source
and bytes preserves the original identity. Worktree retirement removes the entry.
The Android package operation finishes with `scripts/result_records.py build-result
--artifact .build/artifacts/android/AstroTops.apk --type android-apk
--output-directory <allocated-directory>`. It checks source and bytes against that
record, then copies the APK into the supplied directory. It writes one
`.AstroTops.apk.in_process` file and replaces `AstroTops.apk` only after the copy is
flushed. Success and caught failure remove the in-process file; a new invocation
overwrites one left by a crash. The native APK remains available to ADB.
Only a completed copy emits `ceratops-builder-output`, naming `AstroTops.apk` in
`artifacts` and `installationArtifactPath`. Ceratops records its size and hash,
runs the required checks and writes the completed build receipt and Git tag.
The Android install operation calls the same owner with `android-deploy`. It
rejects missing export records or changed source/bytes before ADB, compares the
APK with the installed base APK, skips redundant reinstallation, checks changed
installs by SHA-256, launches the app, and emits the declared deployment receipt.

`scripts/result_records.py` and its `ResultStore` are the sole storage owner for
tracked validation, grouped-test, and build metadata. The grouped test runner
and repository validator call that owner instead of writing records directly.
A candidate run made with `--source-tag` and `--artifact` can still export a
historical report. Normal delivery consumes shared SDLC check outcomes and the
completed-export entry. The obsolete tracked-report delivery gate is removed.

The check-history reader accepts current `ceratops-build-result.v4` receipts in
`.build/members/<type>/<name>/<version>/[<target>/]` and
`.build/bundles/<name>/<version>/[<target>/]`. It reads each receipt's tagged
`check_summary.json` for reuse, without opening packages or scanning another
checkout. Receipts in unsupported formats supply no reusable results.
