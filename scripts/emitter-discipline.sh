#!/usr/bin/env bash
# Emitter registry completeness.
#
# src/emitter_discipline_test.zig enforces the encoding rule on the emitters it
# knows about. This catches the other failure: a new emitter module that is
# never registered, and therefore inherits none of the checks.
#
# Run from the release gate and from `zig build test-emitter-discipline`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REGISTRY="src/emitter_discipline_test.zig"
FAIL=0

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*"; FAIL=1; }

note "Emitter registry completeness"

shopt -s nullglob
emitters=(src/*_emit.zig)
shopt -u nullglob

if [[ ${#emitters[@]} -eq 0 ]]; then
  fail "no src/*_emit.zig modules found — has the naming convention changed?"
fi

for path in "${emitters[@]}"; do
  name="$(basename "$path")"
  if grep -q "@embedFile(\"${name}\")" "$REGISTRY"; then
    pass "${name} is registered"
  else
    fail "${name} is not registered in ${REGISTRY}"
    printf '         Add it to the registry so its output encoding is enforced.\n'
  fi
done

# Any module that writes an artifact family for machine consumers should route
# through the sink. This is advisory for modules outside the *_emit.zig naming
# convention, but a hard failure for one that imports the encoder and then
# bypasses it.
note "Encoder imported but unused"
while IFS= read -r path; do
  if grep -q 'structured_out.zig' "$path" && ! grep -qE 'Sink|structured_out\.' "$path"; then
    fail "$(basename "$path") imports structured_out but never uses it"
  fi
done < <(grep -rl 'structured_out.zig' src/ 2>/dev/null || true)
[[ $FAIL -eq 0 ]] && pass "no dangling encoder imports"

if [[ $FAIL -ne 0 ]]; then
  printf '\nemitter-discipline: FAILED\n'
  exit 1
fi
printf '\nemitter-discipline: ok\n'
