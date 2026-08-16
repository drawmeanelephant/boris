## 395: layout-selection outcomes are machine-readable

`boris build --report PATH` / `validate --report PATH` now include an
informational `ILAYOUTSELECTED` finding per page whose layout was picked by a
rule (`id:` / `glob:` / `role:`), recording the selector and winning layout
path on the page's content-root-relative source path. Fallback layouts emit
nothing, so rule-less sites see zero extra diagnostics. The finding is
severity `info` — it appears in reports with the same stable shape as errors
but never affects `errorCount` or exit codes. `I` is the new informational
code prefix in the closed diagnostics set, documented in
`docs/contracts/diagnostics.md` for tool authors. No change to the layout
model or selection behavior.
