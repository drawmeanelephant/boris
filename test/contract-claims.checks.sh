#!/usr/bin/env bash
# Executable checks for records in test/contract-claims.txt.
#
# Sourced by scripts/test-contract-claims.sh, which provides:
#   $BORIS   absolute path to the installed boris binary
#   $CC_OUT  scratch directory inside the ignored .zig-cache tree
#   cc_detail()  print an indented detail line
#
# Contract for a check function:
#   * return 0 when the contract claim is honored by the implementation;
#   * return non-zero (printing why via cc_detail) when it is not;
#   * never exit, never mutate the working tree, never write outside $CC_OUT.
#
# Checks are deliberately black-box: they drive the installed binary the way a
# user or CI does. They must not re-implement compiler logic — a check that
# re-derives what the compiler does would pass even when the compiler is wrong.
#
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash): no associative
# arrays, no bash-4+isms.
# shellcheck shell=bash

# One page whose frontmatter carries $2 as the parent key, compiled alone.
# Echoes the combined output; sets cc_rc to the exit status.
cc_compile_one_page() {
  local corpus="$1" key="$2"
  rm -rf "$corpus/in" "$corpus/out"
  mkdir -p "$corpus/in"
  printf -- '---\ntitle: Probe\n%s: guides/intro\n---\n\nBody.\n' "$key" > "$corpus/in/page.md"
  set +e
  cc_rc_out="$("$BORIS" --input "$corpus/in" --out "$corpus/out" --quiet 2>&1)"
  cc_rc=$?
  set -e
}

# The author-facing parent key is `parent` only; the legacy names must be
# rejected as unknown frontmatter keys rather than silently accepted as
# aliases. The second assertion is the one with teeth: if `parentEntry` were
# quietly mapped to `parent`, the page would instead fail later with
# EPARENTMISSING for the absent parent id.
contract_check_parent_legacy_keys_rejected() {
  local corpus="$CC_OUT/parent-legacy" key
  for key in parentEntry parent_entry; do
    cc_compile_one_page "$corpus" "$key"
    if [[ "$cc_rc" -ne 1 ]]; then
      cc_detail "$key: expected exit 1, got $cc_rc"
      cc_detail "$cc_rc_out"
      return 1
    fi
    case "$cc_rc_out" in
      *EFRONTMATTER*) ;;
      *)
        cc_detail "$key: expected an EFRONTMATTER diagnostic, got:"
        cc_detail "$cc_rc_out"
        return 1
        ;;
    esac
    case "$cc_rc_out" in
      *EPARENTMISSING*)
        cc_detail "$key: accepted as an alias for \`parent\` (EPARENTMISSING for the absent"
        cc_detail "parent id); the contract forbids this silent mapping"
        return 1
        ;;
    esac
  done
  return 0
}

# A `parent` id that is not present in the page set is a graph error. The
# positive control (parent present) is what makes this a claim about the
# parent edge rather than about the corpus compiling at all.
contract_check_parent_must_exist() {
  local corpus="$CC_OUT/parent-missing" out rc
  rm -rf "$corpus"
  mkdir -p "$corpus/missing/guides"
  printf -- '---\ntitle: Child\nparent: guides/intro\n---\n\nChild body.\n' > "$corpus/missing/guides/child.md"

  set +e
  out="$("$BORIS" --input "$corpus/missing" --out "$corpus/out-missing" --quiet 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 1 ]]; then
    cc_detail "absent parent id: expected exit 1, got $rc"
    cc_detail "$out"
    return 1
  fi
  case "$out" in
    *EPARENTMISSING*) ;;
    *)
      cc_detail "absent parent id: expected EPARENTMISSING, got:"
      cc_detail "$out"
      return 1
      ;;
  esac

  # Positive control: declare the parent and the same page set must compile.
  printf -- '---\ntitle: Intro\n---\n\nIntro body.\n' > "$corpus/missing/guides/intro.md"
  set +e
  out="$("$BORIS" --input "$corpus/missing" --out "$corpus/out-present" --quiet 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    cc_detail "present parent id: expected exit 0, got $rc"
    cc_detail "$out"
    return 1
  fi
  return 0
}

# A CLI usage error is exit 2, not exit 1, and is not a build-report entry.
contract_check_usage_error_exits_2() {
  local out rc
  set +e
  out="$("$BORIS" --definitely-not-a-boris-flag 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 2 ]]; then
    cc_detail "expected exit 2 for an unknown option, got $rc"
    cc_detail "$out"
    return 1
  fi
  case "$out" in
    *EUSAGE*|*"unknown option"*) return 0 ;;
    *)
      cc_detail "expected a usage diagnostic on stderr, got:"
      cc_detail "$out"
      return 1
      ;;
  esac
}

# A missing content root is a pure I/O failure: exit 3, not exit 1, and the
# diagnostic is EIO.
contract_check_io_failure_exits_3() {
  local out rc
  rm -rf "$CC_OUT/absent-root"
  set +e
  out="$("$BORIS" --input "$CC_OUT/absent-root" --out "$CC_OUT/out-io" --quiet 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 3 ]]; then
    cc_detail "expected exit 3 for a missing content root, got $rc"
    cc_detail "$out"
    return 1
  fi
  case "$out" in
    *EIO*) return 0 ;;
    *)
      cc_detail "expected an EIO diagnostic, got:"
      cc_detail "$out"
      return 1
      ;;
  esac
}

# KNOWN DIVERGENCE (issue #907) — this check asserts the *contract-violating*
# parse, so it passes while the divergence is present and fails the moment the
# upstream fix lands. That failure is the signal to flip the record to
# `enforced` and assert the correct name instead.
#
# The contract says the `{` closing a multiword name must touch the name. The
# pinned Oliver parser instead scans to the first `{` on the line, so a braced
# word later in the sentence is absorbed into the name and the prose between
# them is dropped from the rendered step.
contract_check_cooklang_name_termination_adjacency() {
  local corpus="$CC_OUT/cooklang-adjacency" out rc
  rm -rf "$corpus"
  mkdir -p "$corpus/in"
  printf -- '---\nid: adjacency\n---\n\nAdd @salt into the {bowl} and stir.\n' > "$corpus/in/index.cook"

  set +e
  out="$("$BORIS" recipe-scale --input "$corpus/in" --id adjacency --factor 2 --cooklang 2>&1)"
  rc=$?
  set -e
  if [[ "$rc" -ne 0 ]]; then
    cc_detail "recipe-scale exited $rc, so the divergence could not be probed:"
    cc_detail "$out"
    return 1
  fi
  case "$out" in
    *'"name": "salt into the"'*) ;;
    *)
      cc_detail "the misparse no longer reproduces: the ingredient name is no longer"
      cc_detail "'salt into the'. If the adjacency guard landed upstream, repin Oliver and"
      cc_detail "flip this record to \`status: enforced\` asserting the correct name."
      return 1
      ;;
  esac
  case "$out" in
    *'"original": "bowl"'*) ;;
    *)
      cc_detail "expected the trailing \`{bowl}\` to be absorbed as the amount, got:"
      cc_detail "$out"
      return 1
      ;;
  esac
  return 0
}
