## Editor

- **Create and Rename dialogs no longer fail silently on an empty path.**
  Clearing the path field and pressing Enter used to swallow the submit in an
  early return with no feedback. The submit action is now natively disabled
  while the trimmed path is empty — the muted state is visible, and the
  browser refuses implicit Enter submission while the only submitter is
  disabled. The App-level guards remain as defense-in-depth.
