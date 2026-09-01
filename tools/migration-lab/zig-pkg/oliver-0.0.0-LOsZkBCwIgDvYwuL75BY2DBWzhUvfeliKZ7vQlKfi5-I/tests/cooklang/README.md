# Vendored Cooklang canonical corpus

`canonical.yaml` is the official `cooklang/spec` canonical test corpus,
version 7, vendored from commit
`6c4788644004e604ae1da110af6d2400e3c9c7b0` (2026-04-10), MIT licensed
(`LICENSE` here is the upstream file).

- SHA-256: `e3dc4fdbc5d883add6b24a971fc5fc07e68edc26d5df5084cf849d649cda98de`
- 60 tests; 15,836 bytes.
- The conformance harness (`tools/cooklang_conformance.zig`) binds this
  file by byte count and digest before running any test, so an edited
  copy fails loudly rather than silently changing the wall.
- Refreshing: replace `canonical.yaml` with a freshly fetched copy and
  update the digest/byte count in the harness and this note. Full
  provenance and usage policy: docs/COOKLANG.md §2 and §8,
  docs/CLEANROOM.md session 21.
