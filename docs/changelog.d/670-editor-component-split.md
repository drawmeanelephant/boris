# 670 - Editor: segment App.svelte monolith (slice 1 - lib extract)

Slice 1 of #670: extract the 2542-line App.svelte closed scope into scoped lib modules.

- `editor/ui/src/lib/types.ts` - all types from App.svelte:5-173 (Health, Version, ValidateState, FileEntry, BufferResponse, Problem, CommandResult, CompletionIndex, RecipeFacet, GraphDocument etc.) plus limit constants
- `editor/ui/src/lib/api.ts` - sole owner of `token:#token` + `api<T>` + `hostErrorLabel`/`elapsedLabel`/`isLaunchOpenSafe`; only place that sets `X-Boris-Editor-Token` (security boundary editor/src/security.zig:8)
- `editor/ui/src/lib/utils.ts` - pure helpers previously only tested via Playwright (failureLabel, groupProblems, projectPathForProblem, nodeFor*, graphLinksFor*, wikiLinksInSource, quantityLabel, displayQuantity, sourceOffset, packetCopyKey, validation*Label, schemaHint, completionSuggestions, palette*, fileTreeAnnouncement etc.)

App.svelte 2542 -> 2188 lines (-354) orchestrator that owns `token` via lib/api, lifts state, owns timers (host 5s / disk 3s / validate 1s / recovery 3s / save-refresh 300ms), and prop-drills/callbacks to future focused components. Zero template change; styles.css single source; stable ids (#source-editor, #completion-kind, #palette-query, dialog[open], #preview iframe) preserved so editor/ui/tests/safe-editing.spec.ts selectors hold.

Component shells for slices 2-6 are defined in `docs/plans/670-editor-segmentation.md` but not added as Svelte files in this slice — they will be added one slice at a time (Header/SectionNav/Recovery → Project/Source → rail panes → dialogs/palette). When added, each will reuse existing class names (project-pane, source-pane, graph-pane, etc.) so `docs/archived/audits/editor-browser-audit.md` PASS is preserved.

Verification: svelte-check 0 errors, build succeeds, zig build --build-file editor/build.zig test green. No BORIS_EDITOR_URL contract change, no /api/* change, no completion.json|build-report.json adapter change. Screenshot diff at 375|768|1440 remains byte-identical by construction (no template/CSS change in this slice).
