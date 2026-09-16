#!/usr/bin/env bash
# Contract-claim gate: make the *load-bearing* claims of the normative
# contracts under docs/contracts/ executable, so a rule the implementation does
# not actually honor fails a gate instead of diverging silently.
#
# Motivated by #907, where a contract stated that the `{` closing a multiword
# Cooklang name "must touch the name" — and spelled out the exact failure if it
# did not — while the pinned parser had never enforced it, and no test, fixture,
# or gate noticed.
#
# Each record in test/contract-claims.txt is verified three ways:
#
#   1. registry hygiene   — required fields present, contract file exists,
#                           known divergences link an issue;
#   2. prose tethering    — the recorded `quote` (and `section`, when present)
#                           still appears verbatim in the named contract after
#                           whitespace normalization. Contract prose cannot
#                           drift out from under its check unnoticed;
#   3. executable claim   — the named check runs the real binary. A
#                           `known-divergence` record passes while the bug
#                           still reproduces, so its eventual fix fails the
#                           gate and forces the record to be reclassified.
#
# Usage:
#
#   bash scripts/test-contract-claims.sh            # enforce every record
#   bash scripts/test-contract-claims.sh --audit    # also list unguarded contracts
#
# Runs on every PR inside `zig build test`. Run from the repository root, or
# through `zig build test-contract-claims`. All scratch trees live under the
# ignored .zig-cache tree.
#
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no associative
# arrays, no bash-4+isms — a vacuous pass would defeat the guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

REGISTRY="test/contract-claims.txt"
CHECKS="test/contract-claims.checks.sh"
CONTRACTS_DIR="docs/contracts"

AUDIT=0
for arg in "$@"; do
  case "$arg" in
    --audit) AUDIT=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

BORIS="$ROOT/zig-out/bin/boris"
[[ -x "$BORIS" ]] || {
  echo "missing installed Boris binary at zig-out/bin/boris (run: zig build)" >&2
  exit 1
}
[[ -f "$REGISTRY" ]] || { echo "missing registry: $REGISTRY" >&2; exit 1; }
[[ -f "$CHECKS" ]] || { echo "missing checks library: $CHECKS" >&2; exit 1; }

CC_OUT=".zig-cache/contract-claims"
[[ "$CC_OUT" == ".zig-cache/contract-claims" ]] || { echo "unsafe scratch path" >&2; exit 1; }
rm -rf "$CC_OUT"
mkdir -p "$CC_OUT"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
warn() { printf '    OK  %s\n' "$*"; }
# Failure detail goes to stderr alongside its FAIL line, so the block stays
# grouped instead of interleaving with the stdout progress stream.
detail() { printf '         %s\n' "$*" >&2; }
cc_detail() { detail "$*"; }
failmsg() { printf '    FAIL %s\n' "$*" >&2; }

# shellcheck source=../test/contract-claims.checks.sh
. "$CHECKS"

# The registry is line-oriented on purpose: a record's `quote` may contain
# `:`, `|`, backticks, and markdown links, so fields are read by stripping a
# literal key prefix rather than by splitting on a delimiter.
normalize() {
  # Collapse all whitespace runs to one space and trim the ends, so a quote may
  # be recorded on a single line even when the contract wraps it across lines.
  printf '%s' "$1" | tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'
}

contract_text() {
  # The contract with whitespace collapsed, for wrapped-quote matching.
  normalize "$(cat "$1")"
}

r_id=""; r_contract=""; r_section=""; r_status=""; r_issue=""; r_quote=""; r_check=""
records=0
enforced=0
divergent=0
failed=0

reset_record() {
  r_id=""; r_contract=""; r_section=""; r_status=""; r_issue=""; r_quote=""; r_check=""
}

# Validate one accumulated record and run its check. Sets `failed` on violation.
finish_record() {
  [[ -n "$r_id" ]] || return 0
  records=$((records + 1))

  local problems=""
  [[ -n "$r_contract" ]] || problems="$problems missing-contract"
  [[ -n "$r_status" ]] || problems="$problems missing-status"
  [[ -n "$r_quote" ]] || problems="$problems missing-quote"
  [[ -n "$r_check" ]] || problems="$problems missing-check"

  case "$r_status" in
    enforced) ;;
    known-divergence)
      # A divergence without a tracked issue is an excuse, not a record.
      [[ -n "$r_issue" ]] || problems="$problems divergence-without-issue"
      ;;
    "") ;;
    *) problems="$problems unknown-status:$r_status" ;;
  esac

  if [[ -n "$problems" ]]; then
    failmsg "$r_id ($r_status) — malformed registry record:$problems"
    detail "every record needs contract, status, quote, and check; known divergences also need an issue"
    failed=$((failed + 1))
    reset_record
    return 0
  fi

  if [[ ! -f "$r_contract" ]]; then
    failmsg "$r_id ($r_status) — contract file not found: $r_contract"
    failed=$((failed + 1))
    reset_record
    return 0
  fi

  # --- prose tethering -----------------------------------------------------
  local text
  text="$(contract_text "$r_contract")"

  case "$text" in
    *"$(normalize "$r_quote")"*) ;;
    *)
      failmsg "$r_id ($r_status) — contract prose drift"
      detail "the recorded quote no longer appears in $r_contract:"
      detail "  \"$(normalize "$r_quote")\""
      detail "re-read the contract section; then either restore the rule or re-tether this record"
      failed=$((failed + 1))
      reset_record
      return 0
      ;;
  esac

  if [[ -n "$r_section" ]]; then
    case "$text" in
      *"$(normalize "$r_section")"*) ;;
      *)
        failmsg "$r_id ($r_status) — contract section drift"
        detail "heading \"$(normalize "$r_section")\" no longer appears in $r_contract"
        failed=$((failed + 1))
        reset_record
        return 0
        ;;
    esac
  fi

  # --- executable claim ----------------------------------------------------
  local check_rc=0
  case "$r_check" in
    script:*)
      local script="${r_check#script:}"
      if [[ ! -x "$script" && ! -f "$script" ]]; then
        failmsg "$r_id ($r_status) — referenced gate not found: $script"
        failed=$((failed + 1))
        reset_record
        return 0
      fi
      # The referenced gate owns its own output; a non-zero status is the signal.
      if bash "$script" >"$CC_OUT/gate.log" 2>&1; then
        check_rc=0
      else
        check_rc=1
        detail "reused gate $script failed; last output:"
        tail -n 8 "$CC_OUT/gate.log" | while IFS= read -r line; do detail "$line"; done
      fi
      ;;
    *)
      if ! declare -F "contract_check_$r_check" >/dev/null 2>&1; then
        failmsg "$r_id ($r_status) — check function not defined: contract_check_$r_check"
        detail "add it to $CHECKS, or reference an existing gate as script:<path>"
        failed=$((failed + 1))
        reset_record
        return 0
      fi
      if "contract_check_$r_check"; then
        check_rc=0
      else
        check_rc=1
      fi
      ;;
  esac

  case "$r_status" in
    enforced)
      if [[ "$check_rc" -eq 0 ]]; then
        pass "$r_id"
        enforced=$((enforced + 1))
      else
        failmsg "$r_id (enforced) — the implementation does not honor this contract claim"
        detail "contract: $r_contract"
        detail "check:    $r_check"
        failed=$((failed + 1))
      fi
      ;;
    known-divergence)
      if [[ "$check_rc" -eq 0 ]]; then
        warn "$r_id (known divergence $r_issue — still reproduces)"
        divergent=$((divergent + 1))
      else
        failmsg "$r_id (known-divergence) — the divergence no longer reproduces"
        detail "the recorded bug looks fixed. Repin/re-verify, then flip this record to"
        detail "\`status: enforced\` with a check asserting the contract-correct behavior."
        detail "tracked as: $r_issue"
        failed=$((failed + 1))
      fi
      ;;
  esac

  reset_record
}

note "contract claims: $REGISTRY"
while IFS= read -r line || [[ -n "$line" ]]; do
  case "$line" in
    ''|'#'*) continue ;;
    'claim id: '*)
      finish_record
      r_id="${line#claim id: }"
      ;;
    'contract: '*) r_contract="${line#contract: }" ;;
    'section: '*) r_section="${line#section: }" ;;
    'status: '*) r_status="${line#status: }" ;;
    'issue: '*) r_issue="${line#issue: }" ;;
    'quote: '*) r_quote="${line#quote: }" ;;
    'check: '*) r_check="${line#check: }" ;;
    *)
      failmsg "unrecognized registry line: $line"
      detail "records use 'key: value' lines; see the header of $REGISTRY"
      failed=$((failed + 1))
      ;;
  esac
done < "$REGISTRY"
finish_record

if [[ "$records" -eq 0 ]]; then
  echo "contract-claims: registry is empty — the gate would pass vacuously" >&2
  exit 1
fi

# --- coverage audit --------------------------------------------------------
# Which normative contracts have no record here? Untethered is not untested:
# many carry dedicated test steps of their own (test-publication-claims,
# test-nostr, test-publication-profile, ...). What this list shows is the gap
# the registry exists to close — contract prose with no *quoted* rule tied to
# an executable check, which is how #907 diverged unnoticed. Treat it as a
# worklist, not as a defect list.
if [[ "$AUDIT" -eq 1 ]]; then
  unguarded=""
  unguarded_count=0
  total=0
  for c in "$CONTRACTS_DIR"/*.md; do
    base="$(basename "$c")"
    # README.md is the index; acceptance.md is a non-normative checklist.
    # (`if` rather than `&& continue`: a false `&&` list aborts under set -e.)
    if [[ "$base" == "README.md" ]]; then continue; fi
    if [[ "$base" == "acceptance.md" ]]; then continue; fi
    total=$((total + 1))
    if ! grep -F -q -x "contract: $c" "$REGISTRY"; then
      unguarded="$unguarded $c"
      unguarded_count=$((unguarded_count + 1))
    fi
  done
  note "coverage audit: $unguarded_count of $total normative contracts have no record in this registry"
  printf '        untethered is not untested — several carry dedicated test steps of their
'
  printf '        own; these are the contract rules still missing a quoted executable tether\n'
  for c in $unguarded; do
    printf '        %s\n' "$c"
  done
fi

rm -rf "$CC_OUT"

if [[ "$failed" -ne 0 ]]; then
  echo "contract-claims: $failed record(s) failed" >&2
  exit 1
fi

note "$enforced enforced, $divergent known divergence(s), $records record(s) total"
echo "contract-claims: all assertions passed"
