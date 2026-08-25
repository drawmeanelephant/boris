# 670 slice 4 — Editor: Graph|Recipe|Theme|Publication|Problems|Preview rail

Slice 4 of #670: extract the rail and publication surfaces from the monolith.

- `editor/ui/src/components/GraphPane.svelte` — props `{activeNode,parentNode,graphChildren,graphSiblings,graphOutgoing,graphBacklinks,graphRelations,bufferWikiLinks,graphStatus,graphPayload,commandRunning}` `graph-pane:styles.css:78` intact
- `editor/ui/src/components/RecipePane.svelte` — props `{activeNode,scaleFactor,visibleScaleView,commandRunning,graphPayload}` `recipe-pane:styles.css:85` + `recipe-table` preserved
- `editor/ui/src/components/ThemePane.svelte` — props `{themeLayoutOpen,closedLayoutSlots,layoutSlotsInBuffer,layoutSlotsMissing,themeAssets,layoutSelections}` `theme-pane:styles.css:128` intact
- `editor/ui/src/components/PublicationPane.svelte` — props `{publicationPayload,publicationStatus,selectedProfile,lastPublicationPlan,commandRunning}` `publication-pane:styles.css:130` intact, restores `github-pages`/`standard-site` fallback-notice and `artifacts/checks/findings/claims` + `no-deployment-verification` qualification
- `editor/ui/src/components/ProblemsPane.svelte` — props `{problemsNotice,problemGroups,staleProblems,commandResult,validateDaemon,validateState,commandStatus,dirty,commandRunning,impactId,copiedPacketKey}` `problems-pane:styles.css:94` + `validation-state-line` + `cook` position confidence restored, `findings`/`impact` analysis-results included
- `editor/ui/src/components/PreviewPane.svelte` — props `{previewData,previewState,previewWidth}` `preview-pane:styles.css:114` + `preview-viewports`/`preview-a11y`/`preview-state` + `Open preview in new tab` + `generation`/`sandbox` preserved

`SourcePane.svelte` now delegates to `GraphPane`/`RecipePane`/`ThemePane`/`PublicationPane`; `App.svelte` `1809 → ~1706` delegates `ProblemsPane`/`PreviewPane` into `workspace-rail:styles.css:40` grid (rail scroll intact, `problems-pane min-height:0` preserved). `styles.css` single source, stable ids preserved.

Verification: `svelte-check` 0 errors, `key-hints` OK (24 across 13 sources), `build` 122.66kB (125 modules), `zig build --build-file editor/build.zig test` green, `test-host`/`contract-fixture` green, `test:e2e` 112/112 green at `375|768|1440`.

Follows `docs/plans/670-editor-segmentation.md` slice 4. Next: slice 5 `Dialogs + Palette` and slice 6 orchestrator cleanup.
