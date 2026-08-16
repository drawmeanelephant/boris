test(editor): conformance coverage for the deleted-file conflict variant

The conformance sweep now drives the deleted-file conflict dialog end to
end, closing the gap where only the external-changes branch was exercised:

- **Keyboard** — Esc keeps editing (dirty buffer survives), Discard changes
  reached via Shift+Tab from the focused primary and confirmed with Enter
  (recovery cleared, editor returns to No file selected), and Enter on the
  focused Re-create file fires a save carrying `recreate: true` while the
  mock keeps 409ing so the buffer survives.
- **Pointer** — clicking Re-create file matches Enter (recreate request
  fires, dialog closes, saved status) and clicking Discard changes matches
  its keyboard path (recovery cleared, no save request).

The mock gained `saveDeleted` / `saveDeletedOnce` options mirroring the
existing conflict modes: always 409 with `status: 'deleted'`, or once then
success. Test-only change.
