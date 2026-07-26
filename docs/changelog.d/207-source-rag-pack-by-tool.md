### Added

- `boris-source-rag` gained `--pack-by=tool`, an output segmentation axis
  orthogonal to `--profile`. Instead of one flat corpus it emits a
  self-contained pack per scope under `packs/`, each with its own `INDEX.md`,
  catalog, manifests, and bundles, so a single pack can be used without the rest
  of the tree. Pack boundaries are derived from `scanDirsForProfile` rather than
  restated, so the packs are the existing profile scopes with `tools` split per
  tool: `core` (`src`, `layouts`, root files), `docs` (`docs`, `content`), one
  pack per `tools/<name>/`, and `tooling` for the remainder of the `tools` scope
  (`scripts`, `test`, `SUPPORT`). Tool packs come from the scanned paths, so a
  new `tools/<name>/` gets a pack with no code change. Tests assert the
  resulting totality property: each profile's scan equals the union of its
  packs, and every scanned directory belongs to exactly one profile scope. The
  root keeps a router `INDEX.md` and a machine-readable `pack_manifest.json`
  listing each pack's authoritative byte count, an approximate token figure with
  its method (`bytes/4`) recorded alongside, and the questions the pack answers.
  `--split-size` and `--bundles-only` compose per pack. The default
  (`--pack-by=none`) output is byte-identical to before.
