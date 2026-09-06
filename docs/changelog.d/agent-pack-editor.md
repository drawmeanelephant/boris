<!--
Filename: agent-pack-editor.md (placeholder; the orchestrator renames it to the PR number)
Keep exactly one category heading.
-->

### Added

- `scripts/agent-pack.sh` gains opt-in `--with-editor`: it builds the
  `boris-editor` host and bundles it with the prebuilt UI shell under
  `ui/dist/`, records `"editor_ui": true` in `MANIFEST.json`, and covers the
  UI files in `SHA256SUMS`. The default kit stays slim. Links:
  [the agent binary kit guide](/docs/AGENT-BINARY-KITS.md),
  [the editor README](/editor/README.md).
