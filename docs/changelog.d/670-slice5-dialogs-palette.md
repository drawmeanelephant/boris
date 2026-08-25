# 670 slice 5 — Editor: Dialogs + Palette

Slice 5 of #670: extract the 5 dialogs + palette from the App.svelte monolith.

- `editor/ui/src/dialogs/ConflictDialog.svelte` — `conflict`/`deletedConflict`/`activePath`/`content`, `handleConflictKeydown:1400`, `conflict = null`/`deletedConflict = false` on close, `Alt+L`/`Alt+D`/`Enter` hints preserved
- `editor/ui/src/dialogs/ResolutionDialog.svelte` — `pendingResolution`/`resolutionPrompt`/`resolutionVerb`, `handleResolutionKeydown`, `pendingResolution = null` on close, `Alt+S`/`Alt+D`
- `editor/ui/src/dialogs/CreateDialog.svelte` / `RenameDialog.svelte` — `value`/`onPathChange` prop-drilled, `handleDialogKeydown` focus-trap, `onClose` clears `createPath`/`renamePath`
- `editor/ui/src/dialogs/DeleteDialog.svelte` — `activePath` + `handleDialogKeydown`
- `editor/ui/src/dialogs/CommandPalette.svelte` — `paletteItems`/`paletteEnabled`/`paletteQuery`/`paletteSelection`, `aria-activedescendant`, `isEnabled`/`onExecute` guard, `handlePaletteBackdrop`, `paletteKeydown`

`App.svelte` `1706 → 1637` now delegates to the 6 dialog components via `bind:dialog` + `onClose`/`onKeydown` props; components never call `fetch`, security boundary stays in `lib/api.ts`. `styles.css` single source, `dialog[open]` + `#palette-query` + `#palette-option-*` ids preserved.

Lint hardening: `editor/ui/scripts/check-key-hints.mjs:1` now scans `19` Svelte sources (`24` hints), handles prop-drilled `onKeydown`/`onClose`/`onPathChange` and `isEnabled`/`onExecute` aliases for `CommandPalette`, and `onCompletionKeydown` for `AuthoringTools`, so extracted hints remain linted.

Verification: `svelte-check` 0 errors, `key-hints OK (24 across 19)`, `build` 127.60kB (131 modules), `zig build --build-file editor/build.zig test` green, `test-host`/`contract-fixture` green, `test:e2e` 112/112 at `375|768|1440`.

Follows `docs/plans/670-editor-segmentation.md` slice 5. Next: slice 6 orchestrator cleanup (`App ~250`).
