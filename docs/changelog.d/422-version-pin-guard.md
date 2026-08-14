### Changed

- The version query + artifact provenance recipe is now guarded by a
  black-box test (`zig build test-version-pin`, part of `zig build test`):
  `boris --version` / `-V` must print exactly the base compiler id from
  `src/pipeline.zig`, real artifact sets (plain, Cooklang, and
  semantic-relations corpora) must record the base or a `+`-suffixed
  variant id in `manifest.json` and `completion.json`, and a tampered
  recorded id is rejected. The documented pin example in
  `docs/contracts/cli.md` must track the compiler id, so the recipe can
  no longer drift silently from the executable behavior.
