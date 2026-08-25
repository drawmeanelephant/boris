### Fixed

- The [editor](/content/guides/editor.md) probes the open file for external
  edits, deletes, and permission changes while you work, and retries
  transient filesystem errors instead of failing the session
  ([#418](https://github.com/drawmeanelephant/boris/issues/418) M11).
