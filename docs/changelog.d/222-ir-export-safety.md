### Security

- Enforced export-path safety policy on direct IR mode, rejecting output equal to or nested under content root, workspace escapes, or output symlinks, mapping configuration/path errors to exit code 2 (usage), and reserving compiler-derived stage paths per [multi-target isolated output contract](/docs/contracts/multi-target-isolated-output.md).
