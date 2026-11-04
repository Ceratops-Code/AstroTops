# Build records

`.build/artifacts/` contains ignored package bytes produced by SDLC package
builds. `.build/builds/` retains historical source-tag reports; these are not the
current deployment gate.

Successful Android export records its source digest and APK descriptor through
`scripts/result_records.py` in the shared current-results store under Git's common
directory. Its `astrotops-android-export.v1` entry is published only after export
succeeds with unchanged source. There is one current Android export per worktree,
with atomic replacement and no separate history file. Repeating identical source
and bytes preserves the original identity. Worktree retirement removes the entry.
The Android package operation finishes with `scripts/result_records.py build-result`;
it compares source and bytes with that record and emits `ceratops-build-result.v1`.
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
