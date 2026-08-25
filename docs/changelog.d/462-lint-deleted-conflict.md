check(editor): lint the deleted-file conflict variant's close paths

The key-hint lint now enforces that both deleted-conflict close paths clear
`deletedConflict` before the dialog closes, mirroring the Load disk version
invariant for the external-changes surface:

- **Discard changes** (`discardDeletedBuffer`) must clear `deletedConflict`
  before `conflictDialog.close()` in source order.
- **Re-create file** (`saveFile(true)`) must clear `deletedConflict` before
  the dialog closes. This check exposed a live gap: the save success path
  closed the dialog before clearing, so a successful re-create briefly left
  stale deleted-file state. `saveFile` now clears `conflict`/`deletedConflict`
  before closing, matching `loadDiskVersion` and `discardDeletedBuffer`.

Self-test fixtures grew to 28 (one pass plus two targeted fails covering
clear-after-close and a missing clear).
