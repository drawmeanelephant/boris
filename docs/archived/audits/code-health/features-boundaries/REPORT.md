# Code-health audit report — feature modules and boundaries

**Card:** [#820](https://github.com/drawmeanelephant/boris/issues/820) (milestone
[Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic
[#807](https://github.com/drawmeanelephant/boris/issues/807))
**Authority:** review only — no product-code changes on this card.
**Commit audited:** `main` @ `cbc9fa9f` (== `origin/main`; branch
`audit/820-features-boundaries`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin 27)
**Gate:** `zig build test` green before probes (exit 0) and re-run green after.

## Setup

- Fresh branch `audit/820-features-boundaries` from `main` tip `cbc9fa9f`.
- Contracts read first (normative): `docs/contracts/cooklang-compatibility.md`,
  `docs/contracts/documentation-intelligence.md`; the editor boundary per
  `publication-model.md` + AGENTS.md, cross-checked against `cli.md`
  (§ stdout machine surface) and `docs/SOURCE-MAP.md`.
- Locus read: `src/recipe_scale.zig` (220), `src/recipe_scale_view.zig` (338),
  `src/intelligence.zig` (353), `src/doctor.zig` (2135, kernel + hostile-input
  fixtures), `editor/src/*` (16 modules), `src/cli.zig` command enum,
  `src/main_dispatch.zig`, `src/publication_checks.zig` (doctor call sites).
- Black-box binary `zig-out/bin/boris` (0.8.2) against the contract fixtures and
  hand-built tmp trees under `/var/folders/…/T/opencode/p1*|p2*`.
- Cross-references honored, not duplicated: focus traps/dialog (#460–#463 on
  #418) untouched; #599 (persisted scaled view) noted, not relitigated.

## Probes run: 8 (4 black-box)

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| B1 | Cooklang scale goldens (`--factor 2`, `--servings 4`) | copy `docs/contracts/fixtures/cooklang-compatibility/content` to tmp; `boris recipe-scale --input content --id carbonara --factor 2 --cooklang` (and `--servings 4`) | exit 0; byte-diff vs committed goldens differs **only** on the `"vcsRevision"` line — contract-pinned: goldens embed the `""` sentinel while "every current emitter writes" the real token (cooklang-compatibility.md:373-380) | Non-issue / packet drift (sentinel, documented) | `recipe_scale_view.zig:79-80`; test `the view records the baked vcs revision in fixed position (#781)`; goldens `expected/recipe-scale-carbonara-x2.json`, `…-servings-4.json` |
| B2 | Cooklang name-termination edges | tmp `.cook` corpus: `Add @salt and @pepper{1}.` / `Add @salt. Then taste.` / `Add @salt into the {bowl} and stir.` / `Mix @half/half{1%cup}`; `boris recipe-scale … --factor 2 --cooklang` | Sigil stop ✓ (`salt`+`pepper`), sentence punctuation ✓ (`salt`), `/` name stays ordinary ingredient ✓ (`recipeRef: null`). **Adjacency ✗: `@salt into the {bowl}` yields name `salt into the`, amount `bowl`; rendered step deletes `bowl` from prose** (`<li>Add salt into the and stir.</li>`, `<li>salt into the — bowl</li>`) | **Confirmed defect → [#907]** | Oliver `tryToken` (pin `d742494`, `cooklang.zig:~815-875`): name scan runs to the first `{` on the line, no adjacency check; seam delegates `src/cooklang_seam.zig:200`; contract claim `cooklang-compatibility.md:94, 99-102` and table row `:76` |
| B3 | Cooklang refusals + #599 boundary | `boris --cooklang --input invalid/content --out .boris`; `--input mixed/content`; `boris --cooklang --input content --out .boris --no-rag` then read `graph.json` | invalid tree: exit 1; mixed tree: `error: ECOOKLANG: content root mixes Cooklang and non-Cooklang page extensions…`, exit 1; `recipe-scale` usage/content errors exit 2/2/2/1 (`--servings 0`, `--factor`+`--servings` together, `--factor some`, missing `--id` page); `graph.json` keeps authored amounts (`400`, `3`) — scaled view is never persisted | Non-issue (contract-conformant) | `recipe-scale` handler `main.zig:401-454`; fixtures `invalid/`, `mixed/`; contract §Operation "scaled view is not written into `graph.json`" |
| B4 | Intelligence: goldens + determinism + write discipline | from repo root: `boris check --input docs/contracts/fixtures/documentation-intelligence/content --format json` (stderr) → diff vs `expected/check.json`; same twice for determinism; `impact guides/reference`, `impact includes/shared.md` (human+json) vs goldens | All four gate goldens byte-match; run-twice byte-identical; include-consumed `guides/exit-codes` absent from findings (`#739` rule holds); root Trunk `index` flagged `unreferenced_page` exactly as the committed golden pins; no `dist/`, `.boris/`, `rag/`, cache writes without `--report` (tmp tree `find` shows only inputs + probe logs) | Non-issue (contract-conformant) | `intelligence.zig:147-197` (include counts as inbound use, parent excluded), goldens `expected/check.json`, `impact.json`, `impact-source.json`; release-gate lanes `scripts/release-gate.sh:580-660` |
| B5 | Intelligence exit classes + JSON stream | `boris impact guides/nonexistent` / `impact "bad id!"` (exit codes captured without pipes); `boris check … --fail-on-unreferenced`; `boris check --report report.json`; JSON stream location | missing/malformed ID → `error: impact target not found`, exit 2; `--fail-on-unreferenced` → exit 1 (finding present); `check` without `--report` exits 0; JSON/human analysis prints to **stderr** and stdout stays empty — this is contract, not drift (cli.md § stdout machine surface: check/impact "without `--report` print the human or JSON analysis to stderr, never stdout") | Non-issue (initially suspect, resolved by cli.md) | `main.zig:2216-2223` (`--report` path else `std.debug.print`); `cli.zig:1831` (flag is check-only); `documentation-intelligence.md:103-127` |
| B6 | Doctor must not be a command (black-box) | `boris --help`; `boris doctor` | `--help` command list has **no** doctor entry; `boris doctor` → `error: unexpected argument: doctor (try --help)`, exit 2 | Non-issue (gap stays closed) | command enum `cli.zig:58-96` (no doctor); `docs/SOURCE-MAP.md:38` "No public `boris doctor` command" |
| B7 | Doctor run creates no publication output | white-box sweep of `src/doctor.zig` + call sites; `rg` for writes; check where findings surface | `doctor.zig` is an in-memory snapshot kernel: the only `writeFile`/`openDir` hits are inside `test` blocks (tmp dirs); production callers are `src/publication_checks.zig` (build-time publication evidence), which writes `_boris/proof/checks.json` **under the target out-dir as intended build evidence** — not a doctor-owned publication path. No standalone doctor execution surface exists to produce output | Non-issue | `doctor.zig:1-5` ("no CLI … no publication writes"), `doctor.zig:2031-2084` (test-only writes), `publication_checks.zig:16,714`; `CHANGELOG.md:92` |
| W1 | Editor boundary (grep + read) | `rg` `oliver|cooklang_seam|recipe_scale|intelligence|@import("../` over `editor/src/`; read `runner.zig`, `graph.zig`, `project.zig`, `server.zig`, `preview.zig`, `validation_daemon.zig` | **Zero** compiler-internal imports in `editor/src/`; the host spawns the `boris` binary with a fixed argv per closed `Mode` enum (build/validate/check/impact/plan/recipe-scale; no arbitrary argv from the UI — `runner.zig:4`); `/api/graph`, `/api/authoring`, `/api/publication` only forward compiler artifacts through contract validation (`graph.zig:1-3` "does not invent nodes, edges, or backlinks"); `project.zig` does an extension scan only ("The editor does not parse Cooklang, Textile, or Markdown", `project.zig:31`); preview/daemon invoke `boris build --incremental` / the fixed validate daemon argv | Non-issue (boundary holds) | `runner.zig:12-19,205-237`, `server.zig:406-413` (typed `runner.Request`), `editor/README.md` ("Boris remains the only parser, graph, validation … authority") |

## Findings

1. **[#907] Confirmed defect (medium, contract/pinned-parser drift):** the
   Cooklang name-termination adjacency rule claimed by
   `cooklang-compatibility.md` ("that `{` **must touch the name**") is not
   enforced by the pinned Oliver `tryToken`; `@salt into the {bowl}` parses
   name `salt into the` with amount `bowl`, deleting prose from the rendered
   step. Black-box repro pasted in #907. The sigil-stop and
   sentence-punctuation conditions hold; only adjacency drifted.
   Remediation is either an Oliver-side guard + repin (preferred) or an
   explicit contract re-claim.

No further Confirmed or Likely findings. The card's "clean-report bar" is met
by the probe table above (B1–B7, W1; black-box pasted in this report and in
#907).

## Non-issue notes recorded for the record

- **#599 (persisted scaled view) stays parked:** B3 confirms the current
  boundary (authored amounts in `graph.json`, scaled view CLI-only). No
  relitigation.
- **`vcsRevision` golden sentinel (B1):** committed goldens intentionally pin
  `""`; byte-stability across commits is the documented design (#781). Any
  local run shows the real token; this is the only diff line against both
  recipe-scale goldens.
- **Check/impact JSON on stderr (B5):** reads as a defect until `cli.md` §
  stdout machine surface is read; the closed stdout-emitting set deliberately
  excludes check/impact without `--report`. Contract-internal consistency held.
- **`impact` on a target without a committed golden:** `impact
  guides/exit-codes.md` (the include-consumed page as a source-endpoint target)
  deterministically reports source endpoint `includes/shared.md` among its
  transitive dependents — contract-conformant (dependents are typed
  endpoints; the schema allows both), unpinned by any committed golden. No
  action; noted so a future golden for that target doesn't read as drift.
- **Doctor performance note in CHANGELOG (#456)** describes incremental
  scanning inside the build-time checks phase; consistent with B7 (doctor is
  build-embedded, not a command).

## Cross-references (tracked elsewhere, not duplicated)

- Focus traps/dialog: #460–#463 on #418 (editor UI; outside this card).
- Persisted scaled view: #599 (parked).
- Cooklang scale persist: parked per #599; scaling itself verified via B1/B3.
