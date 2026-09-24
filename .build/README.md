# Build records

`.build/artifacts/` contains ignored package bytes produced by SDLC package
builds. `.build/builds/` contains tracked metadata for qualified artifacts,
including the immutable source-tag version, resolved source commit, digest,
length, and approval slot.

The Android package operation finishes by calling
`scripts/result_records.py build-result`; that read-only step hashes the exact
APK and emits the structured build receipt consumed by the SDLC runner.

The grouped test runner is the only metadata writer. A candidate run made with
`--source-tag` and `--artifact` binds its results to the exact package bytes.
Delivery uses `--verify-delivery`; it checks those retained outcomes and bytes
without rebuilding or rerunning tests.
