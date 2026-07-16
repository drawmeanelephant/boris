#!/usr/bin/env bash
# Reproducible coverage for release-gate step 7 Git worktree detection.
#
# Failure mode under test:
#   Linked worktrees store `.git` as a *file* (gitdir pointer), not a directory.
#   The old gate predicate `[[ -d .git ]]` was false in worktrees and skipped the
#   tracked/untracked generated-output cleanliness checks.
#
# This script:
#   1. Asserts the current tree is a Git worktree via `git rev-parse`.
#   2. Creates a temporary linked worktree and proves:
#        - `.git` is not a directory there
#        - `git rev-parse --is-inside-work-tree` is true
#        - the old `[[ -d .git ]]` predicate would incorrectly skip
#        - the new Git-native predicate would run the cleanliness step
#   3. Greps scripts/release-gate.sh for the fixed detection (no `-d .git`).
#
# Run from any checkout of this repo:
#   ./scripts/test-release-gate-git-detection.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GATE_SCRIPT="${ROOT}/scripts/release-gate.sh"
FAIL=0

pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*"; FAIL=1; }

note() { printf '==> %s\n' "$*"; }

# Same predicate as release-gate.sh step 7 (must stay in sync).
in_git_work_tree() {
  command -v git >/dev/null && git rev-parse --is-inside-work-tree >/dev/null 2>&1
}

# Old, incorrect predicate (documented for regression coverage only).
legacy_d_git_dir_check() {
  command -v git >/dev/null && [[ -d .git ]]
}

note "0. Preconditions"
command -v git >/dev/null || { echo "git not on PATH"; exit 1; }
[[ -f "${GATE_SCRIPT}" ]] || { echo "missing ${GATE_SCRIPT}"; exit 1; }
if ! in_git_work_tree; then
  echo "not inside a git work tree; cannot run this test"
  exit 1
fi
pass "git and release-gate.sh available; inside a work tree"

note "1. release-gate.sh uses Git-native detection (not -d .git)"
# Flag live shell predicates only (comments may still document the old bug).
if grep -nE '^[[:space:]]*(if|elif|while|until).*(\[\[.*-d[[:space:]]+\.git|test[[:space:]]+-d[[:space:]]+\.git)' \
  "${GATE_SCRIPT}" >/dev/null 2>&1 \
  || grep -nE '^[[:space:]]*(\[\[|test)[[:space:]].*-d[[:space:]]+\.git' \
  "${GATE_SCRIPT}" >/dev/null 2>&1; then
  fail "release-gate.sh still uses [[ -d .git ]] / test -d .git for cleanliness gating"
else
  pass "no live -d .git cleanliness predicate in release-gate.sh"
fi
if grep -q 'rev-parse --is-inside-work-tree' "${GATE_SCRIPT}"; then
  pass "release-gate.sh uses git rev-parse --is-inside-work-tree"
else
  fail "release-gate.sh missing git rev-parse --is-inside-work-tree"
fi

note "2. Current checkout: new vs legacy detection"
if in_git_work_tree; then
  pass "current tree: Git-native check reports inside work tree"
else
  fail "current tree: Git-native check failed unexpectedly"
fi
if [[ -d .git ]]; then
  pass "current tree: .git is a directory (primary checkout) — legacy would also run"
elif [[ -f .git ]]; then
  if legacy_d_git_dir_check; then
    fail "linked worktree: legacy [[ -d .git ]] unexpectedly true"
  else
    pass "linked worktree: legacy [[ -d .git ]] would skip (the original bug)"
  fi
  if in_git_work_tree; then
    pass "linked worktree: Git-native check still runs cleanliness"
  else
    fail "linked worktree: Git-native check failed"
  fi
else
  fail "current tree: .git is neither file nor directory"
fi

note "3. Temporary linked worktree isolation"
WT_PARENT="$(mktemp -d "${TMPDIR:-/tmp}/boris-rg-wt.XXXXXX")"
WT_PATH="${WT_PARENT}/linked"
cleanup_wt() {
  # Best-effort remove; ignore errors so primary failures stay visible.
  git worktree remove --force "${WT_PATH}" >/dev/null 2>&1 || true
  rm -rf "${WT_PARENT}" >/dev/null 2>&1 || true
}
trap cleanup_wt EXIT

# Detached HEAD at current commit — no branch name pollution.
if ! git worktree add --detach "${WT_PATH}" HEAD >/dev/null 2>&1; then
  fail "git worktree add failed (cannot create linked worktree)"
else
  pass "created temporary linked worktree at ${WT_PATH}"
  # Stay in the parent shell so pass/fail update FAIL; restore cwd afterward.
  _prev_cwd="$PWD"
  cd "${WT_PATH}"
  if [[ -d .git ]]; then
    fail "linked worktree has .git as directory (unexpected for git worktree add)"
  elif [[ -f .git ]]; then
    pass "linked worktree .git is a file (gitdir pointer)"
  else
    fail "linked worktree missing .git"
  fi

  if legacy_d_git_dir_check; then
    fail "linked worktree: legacy [[ -d .git ]] would run (expected skip/false)"
  else
    pass "linked worktree: legacy [[ -d .git ]] is false (would skip cleanliness)"
  fi

  if in_git_work_tree; then
    pass "linked worktree: Git-native check is true (cleanliness would run)"
  else
    fail "linked worktree: Git-native check is false"
  fi

  # Light smoke: the same git commands step 7 uses must work here.
  if git ls-files >/dev/null 2>&1 \
    && git status --porcelain --untracked-files=all >/dev/null 2>&1; then
    pass "linked worktree: git ls-files and status --porcelain work"
  else
    fail "linked worktree: git ls-files/status failed"
  fi
  cd "${_prev_cwd}"
fi

echo
if [[ "${FAIL}" -ne 0 ]]; then
  echo "RELEASE-GATE GIT DETECTION TEST FAILED"
  exit 1
fi
echo "RELEASE-GATE GIT DETECTION TEST PASSED"
exit 0
