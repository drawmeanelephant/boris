#!/usr/bin/env bash
# One-shot gate mirroring the CI `release-html-smoke` lane, so the local and
# CI checks cannot drift. Builds a ReleaseSafe binary (a release-only crash
# class is invisible in Debug — see the lane comment in
# .github/workflows/ci.yml) and runs the release HTML publication smoke
# (`zig build test-release-html-smoke`), then ends with the standard gate
# NDJSON summary line (scripts/gate-lib.sh / scripts/gate-summary.mjs). Run
# from the repository root:
#
#   bash scripts/gate-release-html-smoke.sh
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/gate-lib.sh
source "$root/scripts/gate-lib.sh"
GATE_EVENT="release-html-smoke-gate"

run_stage "build ReleaseSafe" zig build -Doptimize=ReleaseSafe
run_stage "ReleaseSafe HTML publication smoke" \
  zig build -Doptimize=ReleaseSafe test-release-html-smoke

printf '\nrelease-html-smoke gate: PASSED\n'
emit_summary true "$total_ms"
