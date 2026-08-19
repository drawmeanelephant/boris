<!--
Filename: 654-editor-validation-state.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Added

- The editor Problems section names the live validation state from the
  `validate-state` channel (issue #654): the shell renders the daemon's last
  reported `idle` / `running` / `success` / `failed` / `stale` state verbatim
  (`Validation passed (cycle N).`, `Validation failed — N problem(s) (cycle
  N).`, `Validation daemon is restarting with backoff.`, …) and, when the open
  buffer is dirty, notes that the shown problems reflect saved files rather
  than the unsaved buffer. Host and compiler are unchanged — the labels come
  only from the `GET /api/validate-state` payload, so no daemon state is
  fabricated, and shells against a compiler without `validate --watch` show no
  daemon labels. Pinned by the Playwright suite; documented in
  [editor/README.md](/editor/README.md).
