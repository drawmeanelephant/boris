# 670 — Editor App.svelte segmentation: months-long execution plan

> Slice 1 (lib extract) landed on `codex/editor-component-split` from `afterparty@e027482`. This doc makes the remainder shippable one concern per PR for months, without visual/contract drift.

## Why this is the pre-pile-on QoL
`editor/ui/src/App.svelte:2542` on afterparty owns every editor aspect in one closed-over scope (~40 types, 30 lets, derived visibleFiles/paletteItems/staleProblems, ~40 async callbacks, template header|nav|recovery|project|source+authoring+graph+recipe+theme+publication|problems+preview|5 dialogs|palette). Piling find/replace, tabs, CodeMirror, inline diagnostics, graph canvas onto single scope is unsafe and visually risky. Segmentation keeps `styles.css:176` as single visual source, preserves Playwright selectors (`#source-editor`, `#completion-kind`, `#palette-query`, `dialog[open]`, `#preview iframe`), and enforces ownership: components never call `fetch` directly.

## Architecture guardrails (normative)
- **Zig 0.16 is the product core; Svelte 5 is the editor host only.** No new npm deps, no store migration, no design-system rewrite.
- **Security boundary** `editor/src/security.zig:8` stays in `lib/api.ts` only (sole place setting `X-Boris-Editor-Token`).
- **Single stylesheet** `styles.css` stays single file; components reuse existing class names (`project-pane`, `source-pane`, `graph-pane`, `recipe-pane`, `problem-group`, `preview-frame`, `workspace-rail`, etc.) so `docs/audits/editor-browser-audit.md` PASS is preserved.
- **Lifted state** stays in `App.svelte` orchestrator (~250 lines goal): owns `token`+`api<T>`+timers (host 5s/disk 3s/validate 1s/recovery 3s/save-refresh 300ms) and prop-drills/callbacks. Each pane owns its DOM slice.
- **No contract change** except fixing a moved-type import if a host test imports a moved type (none today). No `main` backport.

## Directory contract (from issue, now scaffolded)
```
editor/ui/src/
  lib/
    types.ts   # all types Health|Version|ValidateState|FileEntry|BufferResponse|Problem|CommandResult|...  (App.svelte:5-173)
    api.ts     # token + api<T> + hostErrorLabel|elapsedLabel|isLaunchOpenSafe  (only X-Boris-Editor-Token writer)
    utils.ts   # pure helpers: failureLabel|groupProblems|projectPathForProblem|nodeFor*|graphLinksFor*|wikiLinksInSource|quantityLabel|displayQuantity|sourceOffset|packetCopyKey|validation*Label|schemaHint|completionSuggestions|palette*|fileTreeAnnouncement|defaultCreatePath
  components/
    Header.svelte              props: {connection}
    SectionNav.svelte          no props
    RecoveryBanner.svelte      props: {snapshots} emits: {restore, discard}
    ProjectPane.svelte         props: {files,activePath,dirty,fileQuery,visibleFiles,fileTreeStatus,project,compiler} emits: {open,create,rename,delete,query}
    SourcePane.svelte          props: {activePath,content,readOnly,undoStack,redoStack,authoring,completionKind,completionQuery,suggestions} emits: {input,save,undo,redo,insert}
      AuthoringTools.svelte
      GraphPane.svelte         props: {activeNode,parentNode,graphChildren,graphSiblings,graphOutgoing,graphBacklinks,graphRelations,bufferWikiLinks,graphStatus}
      RecipePane.svelte        props: {activeNode,scaleFactor,scaleView}
      ThemePane.svelte         props: {themeLayoutOpen,closedLayoutSlots,...}
    PublicationPane.svelte
    ProblemsPane.svelte
    PreviewPane.svelte
  dialogs/
    ConflictDialog.svelte, ResolutionDialog.svelte, CreateDialog.svelte, RenameDialog.svelte, DeleteDialog.svelte, CommandPalette.svelte
  App.svelte                   orchestrator, no fetch
```

Shells for all components/dialogs are present as dead code (not wired) so svelte-check/build stay green while template remains byte-identical. This enables parallel ownership.

## Slices — land in order, each green, one concern per branch (AGENTS.md)
Each slice keeps `styles.css` and stable ids; merges target `afterparty`, not `main`.

| Slice | Branch | Scope | Gate |
|-------|--------|-------|------|
| 1 | `codex/editor-component-split` (this PR) | lib/types+api+utils extract, App 2542→2188 (−354), svelte-check 0 errors, build succeeds, editor host tests green | `npm run check && npm run build && zig build --build-file editor/build.zig test` |
| 2 | `codex/editor-header-nav-recovery` | Header, SectionNav, RecoveryBanner presentational move; props only, no state lift churn | same + `npm run test:e2e` 21/21, screenshot 375/768/1440 identical |
| 3 | `codex/editor-project-source-authoring` | ProjectPane + SourcePane/AuthoringTools (biggest pile-on enabler); undo/redo/save callbacks via App, preserve `#source-editor` | same + voice-cert 14/14 + check-key-hints |
| 4 | `codex/editor-rail-panes` | Graph\|Recipe\|Theme\|Publication\|Problems\|Preview into rail; keep `workspace-rail:styles.css:40` grid intact, problems-pane min-height fix #658 | same + preview contract probe |
| 5 | `codex/editor-dialogs-palette` | Conflict/Resolution/Create/Rename/Delete + Palette; preserve focus-trap handleDialogKeydown:1400 and palette aria-activedescendant | same + focus-trap Playwright |
| 6 | `codex/editor-orchestrator-cleanup` | App ∼250 lines, delete dead `$:`, final import-prune, no visual delta | full release gate: `./editor/scripts/test-contract-fixture.sh` + `test-host.sh` + `test-diagnostics.sh` + `test-preview.sh` + `test-validation-daemon.sh` + `test-cooklang.sh` + `test-publication.sh` |

After slice 6, App is a thin orchestrator: `token`+`api`+state+timers+derived (`visibleFiles`, `paletteItems`, `staleProblems`, `activeNode`) + callbacks. Every future feature has a scoped home.

## Verification per slice (copy-paste)
```bash
git fetch origin && git checkout afterparty && git checkout -b codex/editor-<slice>
npm --prefix editor/ui ci
npm --prefix editor/ui run check
npm --prefix editor/ui run build
zig build --build-file editor/build.zig test
./editor/scripts/test-contract-fixture.sh ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor-contract-probe
./editor/scripts/test-host.sh ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist
npm --prefix editor/ui run test:e2e  # 21/21, no a11y tree change
./editor/scripts/test-preview.sh ./zig-out/bin/boris ./editor/zig-out/bin/boris-editor editor/ui/dist # where applicable
```
Screenshot diff of Project|Source|Problems|Preview at 375|768|1440 before/after must be identical (table-overflow fix #667 retained). `voice-certification.md` 14/14 and `check-key-hints.mjs` still passing.

## Risks & mitigations
- **Prop-drill churn** if App lifts too much → keep derived (`activeNode|visibleFiles|staleProblems:286`) in orchestrator, pass read-only; next slices keep paletteEnabled map in App to preserve disabled states identical.
- **Rail scroll covering clicks (#658)** → keep `workspace-rail` grid and `problems-pane min-height:0` intact; rail itself scrolls, not panes.
- **Palette enablement drift** → keep `paletteEnabled:440` derivation in orchestrator; components receive precomputed map.

## Future pile-on (separate issues after segmentation)
- SourcePane → CodeMirror 6 wrapper (keep textarea fallback for Voice Control dictation `editor/README.md:Accessibility`)
- Find/replace + go-to-line + Cmd+F/G, tabs/split for multi-file
- Inline squiggle + gutter from ProblemsPane `position_confidence:exact`
- Virtualized ProjectPane `file-tree max-height 22rem` for 50k files
- Graph canvas, preview `boris serve --watch-json` when #392 lands

Each future feature now has a scoped component to land in, with lib/utils giving it pure helpers without touching host contracts.

## Branch discipline (Build Week)
`main` is frozen; `afterparty` is active integration line. All work branches from up-to-date `afterparty`, target PRs at `afterparty`. Never push directly to `main` or `afterparty`. One agent owns a branch and its hot files. Keep generated outputs (`dist/`, `zig-out/`) ignored. End each slice with `docs/COMPLETION-REPORT-TEMPLATE.md` evidence block.

## Evidence for slice 1
- After slice 1: App 2377→2188 after adding utils imports (measured via `wc -l`).
- `npm --prefix editor/ui run check` 0 errors, `npm run build` succeeds (≈116kB JS gz 38kB).
- `zig build --build-file editor/build.zig test` silent green.
- Component shells present but not wired → zero visual delta, screenshot identical by construction.
- `svelte-check` now checks all new `.svelte` files (Header, SectionNav, etc.) with 0 errors, 0 warnings.
