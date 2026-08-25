---
name: Completion Report
about: Standalone completion report when no PR is filed
title: "Completion Report: "
labels: documentation
---

<!-- Canonical completion report for non-PR work. Mirrors .github/PULL_REQUEST_TEMPLATE.md. Pointer: docs/COMPLETION-REPORT-TEMPLATE.md -->

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
