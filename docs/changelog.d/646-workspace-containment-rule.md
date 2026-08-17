<!--
Filename: 646-workspace-containment-rule.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Changed

- The workspace-containment rule is now specified, not discovered: every
  output tree (HTML, IR, RAG, context, `llms.txt`) is confined to the process
  cwd with a path-component boundary check, violations fail `WorkspaceEscape`
  (exit 2), and the workspace root / content root are `TargetOutputCollision`.
  Absolute output paths resolve inside the workspace are accepted uniformly
  across exporters — there is no IR-specific absolute-path rejection — and
  single-file `--report` outputs plus `--input` remain unconstrained. Pinned
  by unit tests and documented in the [CLI contract](/docs/contracts/cli.md).
