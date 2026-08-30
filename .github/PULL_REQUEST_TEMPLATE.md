# Pull Request

<!-- Canonical completion report — fill out for every substantive PR. Pointer: docs/COMPLETION-REPORT-TEMPLATE.md -->

### Agent Completion Report

- **Status**: [complete | partial | blocked]
- **Branch and Worktree**:
  - Branch: `<branch-name>`
  - Worktree: `<worktree name or branch — never a host absolute path>`
- **Commit and PR**:
  - Commit: `<commit-hash-or-uncommitted>`
  - Target PR / Branch: `<pr-number-or-target-branch>`
- **Linked Issues (auto-close convention)**:
  - **`Closes #N, #M`** in the PR body when the merged change is the
    authoritative fix — GitHub auto-closes those issues on merge.
  - **`Refs #N` / `Related to #N`** when an issue must stay open for manual
    verification after merge (e.g. an audit card the owner inspects before
    closing).
  - Be explicit about which is which; never leave the close-vs-reference
    intent ambiguous.
- **Changed Files**:
  - `<file-path-1>`
  - `<file-path-2>`
- **Preserved Unrelated Files**:
  - `<affirmation-or-list-of-preserved-unrelated-files-and-worktrees>`
- **Implementation Summary**:
  - `<concise-bulleted-summary-of-work-completed>`
- **Known Gaps**:
  - `<unresolved-edge-cases-limitations-or-deferred-scope>` (or `None`)
- **Exact Commands Run**:
  1. `<command-1>`
  2. `<command-2>`
- **Exact Gate Results**:
  - `<gate-command-1>`: `<pass | fail | output-summary>`
  - `<gate-command-2>`: `<pass | fail | output-summary>`
- **Determinism Result**:
  - `<status-and-notes-on-reproducible-deterministic-output>` (or `N/A`)
- **Generated Artifacts**:
  - `<list-of-untracked-generated-outputs-logs-or-scratch-files>` (or `None`)
- **Blockers and Next Card**:
  - Blockers: `<active-blockers-if-any>` (or `None`)
  - Next Card: `<recommended-remediation-or-next-task-card>`
