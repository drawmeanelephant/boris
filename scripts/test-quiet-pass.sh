#!/usr/bin/env bash
# Black-box guard for issue #768: a PASSING `zig build` test step must never
# look like a failure. The Zig 0.16 build runner captures a unit-test binary's
# stderr and re-prints it on the step even when every test passes, appending
# a red `failed command:` line under the default verbose error style. Boris
# negative-path tests used to leave expected error prose on stderr, so green
# runs intermittently displayed phantom failure blocks. Product code now
# suppresses diagnostic prose in test binaries (diag.text_suppressed defaults
# to builtin.is_test); this guard fails if the echo ever comes back.
#
# Run from the repository root, or through:
#
#   zig build test-quiet-pass
#
# All generated trees live under the ignored .zig-cache tree.
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms — a vacuous pass would defeat the guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

OUT=".zig-cache/quiet-pass"
[[ "$OUT" == ".zig-cache/quiet-pass" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

note "test-embed-wasm green run emits no failure-shaped output"
# File redirect (not pure substitution) so the byte-exact grep sees the raw
# interleaved stdout+stderr exactly as a developer would.
set +e
zig build test-embed-wasm >"$OUT/output.tmp" 2>&1
rc=$?
set -e
[[ "$rc" -eq 0 ]] || fail "test-embed-wasm exited $rc, expected 0 (output in $OUT/output.tmp)"
if grep -q '^failed command:' "$OUT/output.tmp"; then
  fail "passing step echoed a 'failed command:' block (#768 regression); see $OUT/output.tmp"
fi
if grep -Eq '^(error|warning): ' "$OUT/output.tmp"; then
  fail "passing step leaked diagnostic prose onto captured stderr; see $OUT/output.tmp"
fi
pass "green run produced no phantom failure output"

rm -rf "$OUT"
echo "quiet-pass: all assertions passed"
