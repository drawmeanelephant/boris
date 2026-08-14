#!/usr/bin/env bash
# Black-box guard for the version query + artifact provenance contract
# (#410/#419, docs/contracts/cli.md "Version query"): `boris --version` and
# `boris -V` must print exactly the base compiler id from src/pipeline.zig on
# stdout, and every artifact set must record that base id or a `+`-suffixed
# variant id (Cooklang / semantic-relations), exactly as the documented pin
# and provenance recipe asserts. Runs on every PR inside `zig build test`.
#
# Run from the repository root, or through:
#
#   zig build test-version-pin
#
# All generated trees live under the ignored .zig-cache tree.
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms — a vacuous pass would defeat the guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/version-pin"
[[ "$OUT" == ".zig-cache/version-pin" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# The base compiler id is the single source of truth (src/pipeline.zig); the
# semantic/recipe ids are the same id plus a `+`-suffixed variant.
BASE_ID="$(sed -n 's/^pub const compiler_id = "\([^"]*\)".*/\1/p' src/pipeline.zig | head -1)"
[[ -n "$BASE_ID" ]] || fail "could not derive compiler_id from src/pipeline.zig"
[[ "$BASE_ID" == boris/[0-9]*\.[0-9]*\.[0-9]* ]] \
  || fail "unexpected base id shape from src/pipeline.zig: '$BASE_ID'"

# --- Version query ---------------------------------------------------------
note "boris --version and -V print exactly the base compiler id on stdout"
for flag in --version -V; do
  set +e
  out="$("$BORIS" "$flag" 2>"$OUT/stderr.tmp")"
  rc=$?
  set -e
  [[ "$rc" -eq 0 ]] || fail "boris $flag exited $rc, expected 0"
  [[ -s "$OUT/stderr.tmp" ]] && fail "boris $flag wrote to stderr: $(cat "$OUT/stderr.tmp")"
  lines="$(printf '%s' "$out" | awk 'END { print NR }')"
  [[ "$lines" -eq 1 ]] || fail "boris $flag printed $lines lines, expected exactly one"
  [[ "$out" == "$BASE_ID" ]] \
    || fail "boris $flag printed '$out', expected '$BASE_ID'"
  pass "boris $flag -> $out"
done

# Short-circuit: trailing junk is unvalidated, exactly like --help.
set +e
out="$("$BORIS" --version --definitely-not-a-flag 2>"$OUT/stderr.tmp")"
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "boris --version with trailing junk exited $rc"
[[ "$out" == "$BASE_ID" ]] \
  || fail "boris --version with trailing junk printed '$out'"
pass "trailing junk after --version is ignored (short-circuit)"

# --- Pin + provenance against built artifact sets --------------------------
# The contract's recipe, exercised verbatim against real IR artifact sets:
#   BORIS_VERSION="$(boris --version)"                      # pin
#   ARTIFACT_ID="$(sed -n 's/.*"compiler": "\([^"]*\)".*/\1/p' manifest.json)"
#   case "$ARTIFACT_ID" in "$BORIS_VERSION" | "$BORIS_VERSION"+*) ;; *) exit 2 ;; esac
#
# build_set: $1 = label, $2 = content root, $3 = expected recorded id,
#            remaining args are forwarded to the build.
build_set() {
  local label="$1" root="$2" expected="$3"
  shift 3
  rm -rf "$OUT/$label"
  mkdir -p "$OUT/$label"
  "$BORIS" --input "$root" "$@" --out "$OUT/$label" --quiet \
    || fail "$label IR build failed"
  [[ -f "$OUT/$label/manifest.json" ]] || fail "$label: manifest.json missing"
  [[ -f "$OUT/$label/completion.json" ]] || fail "$label: completion.json missing"
  local artifact_id recorded
  # manifest.json records the id under `compiler`; completion.json under
  # `compiler_id` — both must satisfy the contract's provenance pattern.
  for recorded in \
      "$(sed -n 's/.*"compiler": "\([^"]*\)".*/\1/p' "$OUT/$label/manifest.json" | head -1)" \
      "$(sed -n 's/.*"compiler_id": "\([^"]*\)".*/\1/p' "$OUT/$label/completion.json" | head -1)"; do
    [[ -n "$recorded" ]] || fail "$label: recorded id empty in an artifact"
    case "$recorded" in
      "$BASE_ID" | "$BASE_ID"+*) ;;  # base or +-suffixed variant id
      *) fail "$label: recorded id '$recorded' is neither '$BASE_ID' nor a +-suffixed variant" ;;
    esac
    [[ "$recorded" == "$expected" ]] \
      || fail "$label: expected '$expected', recorded '$recorded'"
  done
  pass "$label artifact set records '$expected'"
}

note "artifact sets record the base id or a +-suffixed variant id"
build_set plain docs/contracts/fixtures/valid/content "$BASE_ID"
build_set cooklang docs/contracts/fixtures/cooklang-compatibility/content "$BASE_ID+cooklang" --cooklang
build_set semantic docs/contracts/fixtures/semantic-relations/content "$BASE_ID+semantic-relations"

# --- Negative: a tampered id must fail the contract's provenance check -----
note "a tampered artifact id is rejected by the contract's provenance check"
WRONG_ID="${BASE_ID}-stale"
cp -R "$OUT/plain" "$OUT/tampered"
sed 's|"compiler": "[^"]*"|"compiler": "'"$WRONG_ID"'"|' \
  "$OUT/tampered/manifest.json" > "$OUT/tampered/manifest.tmp" \
  && mv "$OUT/tampered/manifest.tmp" "$OUT/tampered/manifest.json"
ARTIFACT_ID="$(sed -n 's/.*"compiler": "\([^"]*\)".*/\1/p' "$OUT/tampered/manifest.json" | head -1)"
[[ "$ARTIFACT_ID" == "$WRONG_ID" ]] \
  || fail "tamper did not take effect: manifest still records '$ARTIFACT_ID'"
set +e
case "$ARTIFACT_ID" in
  "$BASE_ID" | "$BASE_ID"+*) rc=0 ;;
  *) rc=2 ;;
esac
set -e
[[ "$rc" -eq 2 ]] \
  || fail "tampered id '$ARTIFACT_ID' passed the provenance check (expected rejection)"
pass "tampered id '$WRONG_ID' rejected (exit 2)"

# --- The documented pin example must match the base id ---------------------
note "the contract's documented pin example tracks the base id"
DOC_PIN="$(sed -n 's/.*BORIS_VERSION" = "\([^"]*\)".*/\1/p' docs/contracts/cli.md | head -1)"
[[ -n "$DOC_PIN" ]] || fail "pin example not found in docs/contracts/cli.md"
[[ "$DOC_PIN" == "$BASE_ID" ]] \
  || fail "docs/contracts/cli.md pins '$DOC_PIN' but the compiler id is '$BASE_ID' (update the example)"
pass "docs/contracts/cli.md pin example '$DOC_PIN' matches"

rm -rf "$OUT"
echo "version-pin: all assertions passed"
