#!/usr/bin/env bash
# One-shot gate mirroring the CI `content-audit-test` lane (the
# `tools/content-audit` standalone tool), so the local and CI checks cannot
# drift. Builds the tool and runs its build-file test suite, then ends with
# the standard gate NDJSON summary line (scripts/gate-lib.sh /
# scripts/gate-summary.mjs). Run from the repository root:
#
#   bash scripts/gate-content-audit.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/gate-lib.sh
source "$root/scripts/gate-lib.sh"
GATE_EVENT="content-audit-gate"

run_stage "content-audit build" \
  zig build --build-file tools/content-audit/build.zig
run_stage "content-audit tests" \
  zig build --build-file tools/content-audit/build.zig test

printf '\ncontent-audit gate: PASSED\n'
emit_summary true "$total_ms"
