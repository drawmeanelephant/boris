#!/usr/bin/env bash
# One-shot gate mirroring the CI `standalone-tools-test` lane (the
# `tools/search-index` and `tools/docs-maintenance` tool gates), so the local
# and CI checks cannot drift. Runs each tool's build-file test suite and ends
# with the standard gate NDJSON summary line (scripts/gate-lib.sh /
# scripts/gate-summary.mjs). Run from the repository root:
#
#   bash scripts/gate-standalone-tools.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/gate-lib.sh
source "$root/scripts/gate-lib.sh"
GATE_EVENT="standalone-tools-gate"

run_stage "rendered-search CLI tests" \
  zig build --build-file tools/search-index/build.zig test
run_stage "docs-maintenance tests" \
  zig build --build-file tools/docs-maintenance/build.zig test

printf '\nstandalone-tools gate: PASSED\n'
emit_summary true "$total_ms"
