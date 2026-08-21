# 670 slice 3 — Editor: ProjectPane + SourcePane/AuthoringTools

Slice 3 of #670: extract the editor surface from the App.svelte monolith.

- `editor/ui/src/components/ProjectPane.svelte` — props `{files,activePath,dirty,fileQuery,visibleFiles,fileTreeStatus,project,compiler}` emits `onOpen(path)`, `onCreate`, `onRename`, `onDelete`, `onQuery(v)`, `file-tree:styles.css:42` intact, `file-filter` + `file-tree` ids preserved
- `editor/ui/src/components/AuthoringTools.svelte` — props `{authoring,authoringStatus,completionKind,completionQuery,suggestions,selectedSuggestion,completionOpen,readOnly}` emits `onKindChange`, `onQueryChange`, `onInsert`, `onRefresh`, `onCompletionKeydown`, `onCompletionOpen`, `combobox-wrap:styles.css:56` + `completion-controls` + `key-hint` preserved, `completion.json` vocabulary intact
- `editor/ui/src/components/SourcePane.svelte` — props `{activePath,content,readOnly,undoStack,redoStack,dirty,saveInFlight,authoring,…,graphPayload,scaleFactor,publicationPayload,…}` emits `onInput`, `onSave`, `onUndo`, `onRedo`, `onInsert`, `onNavigate`, `onOpenGraph*`, `onPrint`, `onRunPlan` etc., owns `source-pane:styles.css:46` + `#source-editor` + `buffer-state` + `inline-problems`, delegates to `AuthoringTools` and (for now) keeps `graph-pane`/`recipe-pane`/`theme-pane`/`publication-pane` inline for slice 4 extraction
- `editor/ui/scripts/check-key-hints.mjs` — scan all `src/**/*.svelte` (7 sources), count `24` hints (`22` in `App` + `2` in `RecoveryBanner`), handle prop-drilled `onCompletionKeydown` (AuthoringTools) and `onRestore` (RecoveryBanner) via `globalBodiesForLint` and `onCompletionOpen` wiring

`App.svelte` `2157 → 1809` (-348) orchestrator now prop-drills to `ProjectPane` + `SourcePane`; components never call `fetch`, security boundary stays in `lib/api.ts`. `styles.css` single source, stable ids preserved.

Verification: `svelte-check` 0 errors, `key-hints` OK (24 across 7 sources), `build` succeeds (118.91kB), `zig build --build-file editor/build.zig test` green, `test-contract-fixture`/`test-host` green, `test:e2e` 112/112 green at `375|768|1440`.

Follows `docs/plans/670-editor-segmentation.md` slice 3. Next: slice 4 `Graph|Recipe|Theme|Publication|Problems|Preview` rail.
