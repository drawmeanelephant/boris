#!/usr/bin/env bash
# Fail a PR when it references open issues without using per-issue closing
# keywords, so multi-issue fixes cannot orphan issues at merge time.
#
# Background (the 2026-09-05 paperwork incident): the morning batch of audit
# PRs (#915-#932) landed while their referenced issues stayed open, because
# GitHub's merge-time auto-close only fires on the exact "keyword #N" form in
# the PR body. A comma-chained list ("Closes #858, #859, #869") closed only
# the first issue; bold-wrapped keywords ("**Closes ... #N**") broke the match
# too. 23 orphaned issues had to be closed by hand. This lint enforces the
# per-issue grammar before merge:
#
#   COVERED    "Closes|Closed|Close|Fixes|Fixed|Fix|Resolves|Resolved|Resolve
#               #N" (case-insensitive, optional colon) — one issue per
#              occurrence, the keyword immediately preceding the number.
#   VIOLATION  (for every OPEN issue referenced in the body):
#   NO-KEYWORD   bare "#N" mention — GitHub will not close it.
#   NONCLOSING   only "Refs #N" / "Related to #N" — declared intent to keep
#                it open; a merge that intends to close must say so.
#   BOLD         keyword wrapped in **emphasis** — did not auto-close (#915).
#   AMBIGUOUS    both a closing keyword and Refs/Related-to for the same
#                issue — close-vs-reference intent is ambiguous (PR template
#                forbids exactly this).
#
# Boundary guards: the keyword must not be part of a longer word or hyphenated
# compound, so prose like "Recloses #N" or "auto-closes #N" never satisfies
# the rule, and a bare "#N" must not be glued to a word, path, or URL —
# "owner/repo#N" and "page.html#N" are other-repository or anchor references
# that GitHub will not auto-close against this repository, so demanding a
# closing keyword for them would be wrong advice. Numbers referenced in other
# PRs are skipped (the issues API marks them), as are already-closed issues
# and PRs that are not open.
#
# Usage:
#   scripts/check-pr-issue-close.sh --selftest            offline, no network
#   scripts/check-pr-issue-close.sh --pr <number> [...]   live, via gh
#   scripts/check-pr-issue-close.sh --body-file <path>    body from file, live
#                                                         issue states via gh
#
# Zero dependencies beyond bash 3.2 + gh. macOS /bin/bash compatible by
# design (no associative arrays, no bash-4+isms): a vacuous pass would defeat
# the guard.
#
# Exit codes: 0 = clean; 1 = violations found; 2 = usage / transport failure.

set -euo pipefail

PROG="check-pr-issue-close"
CLOSING_RE='(^|[^A-Za-z-])(Closes|Closed|Close|Fixes|Fixed|Fix|Resolves|Resolved|Resolve)[[:space:]]*:?[[:space:]]*#[0-9]+'
NONCLOSING_RE='(^|[^A-Za-z-])(Refs|Related to)[[:space:]]*:?[[:space:]]*#[0-9]+'
BOLD_SPAN_RE='\*\*[^*]+\*\*'
# A same-repo issue reference is a bare "#N" not glued to a word, path, or URL
# fragment: "owner/repo#N" and "page#N" are cross-repo or anchor forms GitHub
# does not auto-close against this repository and are not references here.
ISSUE_REF_RE='(^|[^A-Za-z0-9/._~-])#[0-9]+'

note() { printf '==> %s\n' "$*"; }
die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

# ---------------------------------------------------------------------------
# Set helpers (bash 3.2/5.x: no associative arrays, no indirect expansion —
# membership via substring; sets are comma-wrapped strings)
# ---------------------------------------------------------------------------

# in_set <needle> <set>: set is a comma-separated string with leading and
# trailing commas, e.g. ",912,913," — as produced by to_set / inline appends.
in_set() {
  case "$2" in *",$1,"*) return 0 ;; esac
  return 1
}

# NOTE: do not use ${!var} indirection or declare-style combined locals that
# expand a variable declared in the same statement — bash 5.x (CI runners)
# rejects "${!__var:-}" evaluated in the same declaration command that
# assigns __var ("invalid indirect expansion"), while bash 3.2 accepts it.

# to_set <newline-separated-list>: wrap into the ",a,b," membership form.
to_set() {
  printf '%s\n' "$1" | awk 'NF { s = s $0 "," } END { printf ",%s", s }'
}

# numbers_matching <text> <regex>: deduped numbers captured by regex, in
# reading order, one per line. Guarded against grep's exit 1 on no match
# (set -o pipefail would otherwise kill the caller).
numbers_matching() {
  local text="$1" re="$2"
  printf '%s\n' "$text" | { grep -oiE "$re" || true; } | { grep -oE '[0-9]+' || true; } \
    | awk '!seen[$0]++'
}

# strip_bold <text>: remove **emphasis** spans so keyword matches inside them
# are not counted as authoritative closing keywords.
strip_bold() {
  printf '%s\n' "$1" | sed -E "s/$BOLD_SPAN_RE/ /g"
}

# strip_code <text>: remove inline code spans (`...`) so issue references the
# way GitHub does not linkify them — inside backticks — do not trip the lint.
# Mirrors GitHub's reference-linkify rules: no auto-close inside code spans.
strip_code() {
  printf '%s\n' "$1" | sed -E 's/`[^`]*`/ /g'
}

# ---------------------------------------------------------------------------
# Body analysis (pure functions — exercised by --selftest)
# ---------------------------------------------------------------------------

# classify_refs <body>: print one "<number> <CLASS>" line per referenced
# number that is not covered by a valid per-issue closing keyword. Classes:
# BOLD, NONCLOSING, NO-KEYWORD. Numbers covered by a plain closing keyword
# are omitted here; the AMBIGUOUS class is reported separately (see below).
classify_refs() {
  local body="$1"
  local norm bold refs all n norm_set bold_set refs_set
  body="$(strip_code "$body")" # code spans are not linkified by GitHub
  norm="$(numbers_matching "$(strip_bold "$body")" "$CLOSING_RE")"
  bold="$(numbers_matching "$body" "$CLOSING_RE")"
  refs="$(numbers_matching "$body" "$NONCLOSING_RE")"
  all="$(numbers_matching "$body" "$ISSUE_REF_RE")"
  norm_set="$(to_set "$norm")"
  refs_set="$(to_set "$refs")"

  # Keep only the bold-only captures (bold minus plain coverage).
  local bold_only="," n2
  while IFS= read -r n2; do
    [[ -n "$n2" ]] || continue
    in_set "$n2" "$norm_set" && continue
    in_set "$n2" "$bold_only" || bold_only="${bold_only}${n2},"
  done < <(printf '%s\n' "$bold")
  # already in membership form: "," when empty, ",a,b," when populated
  bold_set="$bold_only"

  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    if in_set "$n" "$norm_set"; then
      continue # covered by a plain per-issue closing keyword
    elif in_set "$n" "$bold_set"; then
      printf '%s BOLD\n' "$n"
    elif in_set "$n" "$refs_set"; then
      printf '%s NONCLOSING\n' "$n"
    else
      printf '%s NO-KEYWORD\n' "$n"
    fi
  done < <(printf '%s\n' "$all")
  return 0 # loop bodies end in `in_set && ...` lists that may fail; never leak
}

# ambiguous_refs <body>: print numbers referenced by BOTH a plain closing
# keyword and a Refs/Related-to form (contradictory intent).
ambiguous_refs() {
  local body="$1" norm refs n norm_set
  body="$(strip_code "$body")" # code spans are not linkified by GitHub
  norm="$(numbers_matching "$(strip_bold "$body")" "$CLOSING_RE")"
  refs="$(numbers_matching "$body" "$NONCLOSING_RE")"
  norm_set="$(to_set "$norm")"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    in_set "$n" "$norm_set" && printf '%s AMBIGUOUS\n' "$n"
  done < <(printf '%s\n' "$refs")
  return 0 # same set -e leak guard as classify_refs
}

# ---------------------------------------------------------------------------
# gh plumbing
# ---------------------------------------------------------------------------

require_gh() {
  command -v gh >/dev/null 2>&1 || die "gh is required but not installed"
}

repo_slug() {
  if [[ -n "${GH_REPO:-}" ]]; then
    printf '%s\n' "$GH_REPO"
  else
    gh repo view --json nameWithOwner -q .nameWithOwner
  fi
}

# issue_kind <number>: echoes one of "open", "closed", "pr" (the number is a
# pull request, not an issue), or "missing" (no such issue — a broken link,
# not this lint's business). Transport failures retry once, then die.
# NOTE: the command substitutions are guarded with `&& rc=0 || rc=$?` —
# under `set -e` a bare failing assignment would exit before the retry /
# 404 handling could run.
issue_kind() {
  local n="$1" path out rc err
  err="$(mktemp)"
  path="repos/$(repo_slug)/issues/$n"
  out="$(gh api "$path" --jq 'if has("pull_request") then "pr" else (.state // "missing") end' 2>"$err")" && rc=0 || rc=$?
  if [[ $rc -ne 0 ]] && ! grep -q 'HTTP 404' "$err"; then
    sleep 2 # transient transport hiccup: one retry
    out="$(gh api "$path" --jq 'if has("pull_request") then "pr" else (.state // "missing") end' 2>"$err")" && rc=0 || rc=$?
  fi
  if [[ $rc -ne 0 ]]; then
    if grep -q 'HTTP 404' "$err"; then
      rm -f "$err"
      printf 'missing\n'
      return 0
    fi
    rm -f "$err"
    die "gh api '$path' failed"
  fi
  rm -f "$err"
  printf '%s\n' "$out"
}

# pr_body <number>: the PR body text; emits an empty sentinel for non-open
# PRs. NOTE: `gh pr view` reports state uppercase (OPEN/CLOSED/MERGED),
# unlike the REST API's lowercase states — normalize before comparing.
pr_body() {
  local pr="$1" state body
  # NOTE: `gh pr view` reports state uppercase (OPEN/CLOSED/MERGED), unlike
  # the REST API's lowercase states — normalize before comparing.
  state="$(gh pr view "$pr" --json state -q .state 2>/dev/null | tr '[:upper:]' '[:lower:]')" \
    || die "could not read PR #$pr"
  if [[ "$state" != "open" ]]; then
    printf '\n' # sentinel: caller skips silently
    return 0
  fi
  body="$(gh pr view "$pr" --json body -q .body)" || die "could not read PR #$pr body"
  printf '%s\n' "$body"
}

# ---------------------------------------------------------------------------
# Live check
# ---------------------------------------------------------------------------

check_pr() {
  local pr="$1" body kind n cls

  body="$(pr_body "$pr")"
  # Empty sentinel = PR not open (merged/closed): nothing to enforce.
  [[ -n "$body" ]] || { note "PR #$pr is not open — skipping."; return 0; }

  local class_out ambiguous
  class_out="$(classify_refs "$body")"
  ambiguous="$(ambiguous_refs "$body")"

  local failures=0 open_count=0 report=""
  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n="${line%% *}"; cls="${line#* }"
    kind="$(issue_kind "$n")"
    case "$kind" in
      pr|missing|closed) continue ;; # not an open issue: nothing to enforce
      open) ;;
      *) die "unexpected issue kind '$kind' for #$n" ;;
    esac
    open_count=$((open_count + 1))
    case "$cls" in
      NO-KEYWORD)
        report+="  #$n has no closing keyword — add a line \"Closes #$n\" (one issue per keyword)$nl" ;;
      NONCLOSING)
        report+="  #$n is only Refs/Related-to — if the merge must close it, add \"Closes #$n\"$nl" ;;
      BOLD)
        report+="  #$n uses a bold-wrapped keyword (**Closes #$n**) which does not auto-close — unwrap it$nl" ;;
      *)
        die "unexpected class '$cls'" ;;
    esac
  done < <(printf '%s\n' "$class_out")

  while IFS= read -r line; do
    [[ -n "$line" ]] || continue
    n="${line%% *}"
    kind="$(issue_kind "$n")"
    [[ "$kind" == "open" ]] || continue
    open_count=$((open_count + 1))
    report+="  #$n is referenced by both a closing keyword and Refs/Related-to — pick one (ambiguous intent)$nl"
  done < <(printf '%s\n' "$ambiguous")

  if [[ $open_count -eq 0 ]]; then
    note "PR #$pr: clean (no open issues referenced without per-issue closing keywords)"
    return 0
  fi
  printf 'FAIL: PR #%s references %s open issue(s) without per-issue closing keywords:\n%s' \
    "$pr" "$open_count" "$report"
  return 1
}

# ---------------------------------------------------------------------------
# Self-test battery (offline, no gh calls)
# ---------------------------------------------------------------------------

selftest() {
  local failures=0 cases=0

  # assert_classes <name> <body> <expected-substring-or-EMPTY>
  assert_classes() {
    local name="$1" body="$2" want="$3" got rc
    cases=$((cases + 1))
    got="$(classify_refs "$body")"
    if [[ -z "$want" && -z "$got" ]]; then return 0; fi
    if [[ -n "$want" && "$got" == *"$want"* ]]; then return 0; fi
    printf '    FAIL selftest: %s\n        want substring: %q\n        got:            %q\n' \
      "$name" "$want" "$got" >&2
    failures=$((failures + 1))
  }

  # assert_ambiguous <name> <body> <expected-substring-or-EMPTY>
  assert_ambiguous() {
    local name="$1" body="$2" want="$3" got
    cases=$((cases + 1))
    got="$(ambiguous_refs "$body")"
    if [[ -z "$want" && -z "$got" ]]; then return 0; fi
    if [[ -n "$want" && "$got" == *"$want"* ]]; then return 0; fi
    printf '    FAIL selftest: %s\n        want substring: %q\n        got:            %q\n' \
      "$name" "$want" "$got" >&2
    failures=$((failures + 1))
  }

  # assert_absent <name> <body> <needle>: classification must NOT contain the
  # needle (used for "this issue is fully covered" assertions).
  assert_absent() {
    local name="$1" body="$2" needle="$3" got
    cases=$((cases + 1))
    got="$(classify_refs "$body")"
    if [[ "$got" != *"$needle"* ]]; then return 0; fi
    printf '    FAIL selftest: %s\n        did not expect: %q\n        got:            %q\n' \
      "$name" "$needle" "$got" >&2
    failures=$((failures + 1))
  }

  note "selftest: classify_refs"

  assert_classes "plain Closes covers the issue" \
    "Closes #912" ""
  assert_classes "case-insensitive keyword with colon and punctuation" \
    "fixes: #912." ""
  assert_classes "FIXES uppercase" \
    "FIXES #912" ""
  assert_classes "Resolves / Resolve / Closed synonyms" \
    "Resolve #912
Closed #913" ""
  assert_classes "markdown bullet before keyword is fine" \
    "- Closes #912" ""
  assert_classes "one issue per Closes line" \
    "Closes #912
Closes #913
Closes #914" ""
  assert_classes "coverage by a later plain line rescues a bold mention" \
    "**See #912** — summary
Closes #912" ""
  assert_classes "em dash prose after the number still closes" \
    "Closes #912 — authoritative fix per audit card" ""

  assert_classes "bare mention is NO-KEYWORD" \
    "See #912" "912 NO-KEYWORD"
  assert_classes "comma list: tail issues are NO-KEYWORD" \
    "Closes #912, #913" "913 NO-KEYWORD"
  assert_absent "comma list: head issue is covered (matches GitHub)" \
    "Closes #912, #913" "912 "
  assert_classes "bold-wrapped single keyword is BOLD" \
    "**Closes #912**" "912 BOLD"
  assert_classes "bold-wrapped list: head BOLD, tail NO-KEYWORD" \
    "**Closes #912, #913**" "913 NO-KEYWORD"
  assert_classes "Refs only is NONCLOSING" \
    "Refs #912" "912 NONCLOSING"
  assert_classes "Related to only is NONCLOSING" \
    "Related to #912" "912 NONCLOSING"
  assert_classes "boundary guard: Recloses is prose" \
    "Recloses #912" "912 NO-KEYWORD"
  assert_classes "boundary guard: auto-closes is prose" \
    "This auto-closes #912 eventually" "912 NO-KEYWORD"
  assert_classes "keyword for a different issue does not cover" \
    "Closes #912
Mentions #913" "913 NO-KEYWORD"

  # Real incident shapes.
  assert_classes "PR #915 shape: bold 12-issue list" \
    "**Closes #855, #856, #863, #864, #873, #888, #889, #897, #898, #901, #902, #911**" \
    "856 NO-KEYWORD"
  assert_classes "PR #917 shape: plain comma list" \
    "Closes #858, #859, #869" "869 NO-KEYWORD"

  # Code spans: GitHub does not linkify references inside backticks, so a
  # mention in inline code is documentation, not an actionable reference.
  assert_classes "code-span mention is not a reference" \
    "Closes #912
Docs say use \`Refs #418\` or bare \`#454\` forms" ""
  assert_ambiguous "code-span mention cannot be ambiguous" \
    "Closes #912
See \`Refs #912\` in the notes" ""

  # Cross-repo and URL-attached references: GitHub links only bare "#N"
  # forms against this repository, so "owner/repo#N" and page/URL fragments
  # must not demand a closing keyword.
  assert_classes "cross-repo owner/repo#N is not a reference" \
    "See drawmeanelephant/boris-migration-lab#584 for the lab story." ""
  assert_classes "URL fragment is not a reference" \
    "Docs: https://github.com/drawmeanelephant/boris/wiki/page#584" ""
  assert_classes "explicit same-repo form is not demanded (GitHub closes it)" \
    "Closes drawmeanelephant/boris#912" ""
  assert_classes "cross-repo mention does not mask a real same-repo flag" \
    "See drawmeanelephant/lab#584 — also mentions #913 bare" "913 NO-KEYWORD"

  note "selftest: ambiguous_refs"
  assert_ambiguous "closing + Refs for the same issue is ambiguous" \
    "Closes #912
Refs #912" "912 AMBIGUOUS"
  assert_ambiguous "different issues are not ambiguous" \
    "Closes #912
Refs #900" ""
  assert_ambiguous "bold-only closing does not conflict with Refs" \
    "**Closes #912**
Refs #912" ""

  if [[ $failures -eq 0 ]]; then
    note "selftest: $cases cases pass"
    return 0
  fi
  printf '%s: %s of %s selftest cases failed\n' "$PROG" "$failures" "$cases" >&2
  return 1
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

nl=$'\n'
mode="${1:-}"
case "$mode" in
  --selftest)
    selftest
    ;;
  --pr)
    shift
    [[ $# -ge 1 ]] || die "--pr requires at least one PR number"
    require_gh
    rc_total=0
    for pr in "$@"; do
      [[ "$pr" =~ ^[0-9]+$ ]] || die "not a PR number: $pr"
      set +e
      check_pr "$pr"
      rc=$?
      set -e
      [[ $rc -eq 0 ]] || rc_total=1
    done
    exit $rc_total
    ;;
  --body-file)
    shift
    [[ -n "${1:-}" && -f "$1" ]] || die "--body-file requires a readable file path"
    require_gh
    body="$(cat "$1")"
    rc_total=0
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n="${line%% *}"; cls="${line#* }"
      kind="$(issue_kind "$n")"
      [[ "$kind" == "open" ]] || continue
      printf 'FAIL: open issue #%s: %s\n' "$n" "$cls"
      rc_total=1
    done < <(classify_refs "$body")
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      n="${line%% *}"
      [[ "$(issue_kind "$n")" == "open" ]] || continue
      printf 'FAIL: open issue #%s: AMBIGUOUS\n' "$n"
      rc_total=1
    done < <(ambiguous_refs "$body")
    exit $rc_total
    ;;
  -h|--help)
    sed -n '2,45p' "$0"
    ;;
  *)
    die "usage: $PROG --selftest | --pr <number> [...] | --body-file <path>"
    ;;
esac
