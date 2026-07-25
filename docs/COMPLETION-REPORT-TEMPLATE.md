# Completion Report Template

This template defines the canonical completion report format for AI agents (and human contributors pairing with them) when completing, pausing, or reporting status on delegated work in Boris.

All substantive agent work must conclude with a report adhering to this template.

---

## Canonical Evidence Block Template

Copy and fill out this structure in the final agent summary or pull request description:

```markdown
### Agent Completion Report

- **Status**: [complete | partial | blocked]
- **Branch and Worktree**:
  - Branch: `<branch-name>`
  - Worktree: `<absolute-path-to-worktree>`
- **Commit and PR**:
  - Commit: `<commit-hash-or-uncommitted>`
  - Target PR / Branch: `<pr-number-or-target-branch>`
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
```

---

## Field Specifications

1. **Status**: Must be exactly one of `complete`, `partial`, or `blocked`.
2. **Branch and Worktree**: Record the active git branch (`git branch --show-current`) and current worktree root path (`git rev-parse --show-toplevel`).
3. **Commit and PR**: Record the head commit hash (`git rev-parse HEAD`) if committed, and the PR number or target branch (e.g. `afterparty` or `main`).
4. **Changed Files**: Full list of modified, added, or deleted files (`git status --short`).
5. **Preserved Unrelated Files**: Explicit statement confirming that unrelated files, dirty working trees, or parallel worktrees were untouched.
6. **Implementation Summary**: Concise, factual summary of structural and logic changes.
7. **Known Gaps**: Explicitly list any incomplete features, known edge cases, or temporary deviations.
8. **Exact Commands Run**: List the precise shell commands executed during work and verification.
9. **Exact Gate Results**: Record pass/fail status and output summaries for test suites and gates (`zig build test`, `./scripts/release-gate.sh`, etc.).
10. **Determinism Result**: Where output determinism matters (e.g. site emit, RAG packs, JSON IR), report results comparing sequential/parallel runs or repeated runs.
11. **Generated Artifacts**: Note any temporary or generated files produced (`dist/`, build artifacts, logs) and confirm whether they remain gitignored or uncommitted.
12. **Blockers and Next Card**: State any ship blockers and define the clear next actionable unit of work / remediation card.
