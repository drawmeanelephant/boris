#!/usr/bin/env bash
# Module-classification completeness, for humans running the release gate.
#
# The authority is src/emitter_discipline_test.zig, which runs inside
# `zig build test` and needs no shell. This mirrors its "every source module is
# classified" check so a reviewer can see the answer without a full test run.
#
# The check is deliberately inverted: it does NOT look for files matching an
# emitter naming convention. Boris's machine-facing emitters are llms.zig,
# context.zig, rag.zig and search_index.zig — none ends in _emit.zig — so a
# name-based check would miss a new rss.zig entirely.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REGISTRY="src/emitter_discipline_test.zig"
FAIL=0

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*"; FAIL=1; }

note "Source module classification"

count=0
for path in src/*.zig; do
  name="$(basename "$path")"
  count=$((count + 1))
  if ! grep -q "\.name = \"${name}\"" "$REGISTRY"; then
    fail "${name} is not classified in ${REGISTRY}"
    printf '         Add it as .other, or as an emitter with the encoder it uses.\n'
  fi
done

if [[ $count -eq 0 ]]; then
  fail "no src/*.zig found — has the layout changed?"
fi

if [[ $FAIL -ne 0 ]]; then
  printf '\nemitter-discipline: FAILED\n'
  exit 1
fi
pass "all ${count} source modules are classified"
printf '\nemitter-discipline: ok\n'
