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
  - **`Closes #N`** in the PR body when the merged change is the
    authoritative fix — GitHub auto-closes the issue on merge. One issue per
    keyword: write a separate `Closes #N` line (or bullet) for every issue;
    comma lists (`Closes #N, #M`) and bold-wrapped keywords (`**Closes #N**`)
    do not auto-close and fail the `pr-issue-close lint` CI check while the
    referenced issue is open.
  - **`Refs #N` / `Related to #N`** when an issue must stay open for manual
    verification after merge (e.g. an audit card the owner inspects before
    closing, or a parent/umbrella issue whose remaining slices are still
    open). The lint accepts this as a declaration that the merge does not
    close the issue and reports it to the reviewer; the issue is never
    auto-closed.
  - **Every open-issue reference must declare one of those two intents.** A
    bare `#N` mention — including one inside a comma list or on a `Closes`
    line that names extra issues — fails the lint while that issue is open,
    because the body does not say whether the merge closes it. Do not combine
    `Closes` and `Refs` for the same issue: the close-vs-keep-open intent must
    stay unambiguous.
  - **Never wrap the keyword or the number in backticks, and never put the
    declaration in a fenced block.** GitHub does not linkify references inside
    code spans or fences, so such a line is inert: the merge neither closes
    the issue nor records the intent, and the lint fails it as INERT. This is
    how #834 was orphaned on 2026-09-11 — the body read `Closes #834` in
    backticks, the PR looked correctly linked, and the merge closed nothing.
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
