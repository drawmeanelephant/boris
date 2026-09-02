#!/usr/bin/env bash
# One-shot editor validation gate. The editor-test CI lane runs this exact
# script (deps pre-installed, see .github/workflows/ci.yml), so the local and
# CI editor validation cannot drift.
#
# Takes a product `boris` binary (e.g. a build of a released tag) and runs
# every editor acceptance surface against it — editor-host Zig tests, UI
# static checks + build, the mocked Playwright e2e suite, and the live
# integration scripts (contract fixture, host safe-editing, diagnostics,
# validation daemon, live preview, publication) that spawn the binary
# through the editor host. Re-verify a released Boris against the editor
# with one command:
#
#   ./editor/scripts/test-editor-gate.sh /path/to/released/boris
#
# First run on a fresh checkout (installs the UI npm deps and the Playwright
# Chromium browser):
#
#   ./editor/scripts/test-editor-gate.sh --deps /path/to/released/boris
#
# The stage/timing/NDJSON machinery comes from the shared scripts/gate-lib.sh;
# every outcome ends with one machine-readable NDJSON line on stdout
# (event "editor-gate"), rendered as the GitHub job summary by
# scripts/gate-summary.mjs, with log + NDJSON uploaded as the
# editor-gate-summary artifact. Per-stage "OK"/"FAIL" lines keep the
# human-readable trail.
#
# test-cooklang.sh (Cooklang-corpus variant) is not part of the CI lane and
# is intentionally left out; the per-surface scripts remain available
# individually.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
cd "$root"
# shellcheck source=scripts/gate-lib.sh
source "$root/scripts/gate-lib.sh"
GATE_EVENT="editor-gate"

usage() {
  echo "usage: $0 [--deps] BORIS_BIN" >&2
  exit "${1:-2}"
}

install_ui_deps() {
  npm --prefix editor/ui ci
  npm exec --prefix editor/ui -- playwright install chromium
}

build_host_binaries() {
  zig build --build-file editor/build.zig
  [[ -x "$root/editor/zig-out/bin/boris-editor" ]] || return 1
  [[ -x "$root/editor/zig-out/bin/boris-editor-contract-probe" ]] || return 1
  [[ -d "$root/editor/ui/dist" ]] || return 1
}

deps=0
boris_arg=""
for arg in "$@"; do
  case "$arg" in
    --deps) deps=1 ;;
    -h | --help) usage 0 ;;
    -*) echo "unknown option: $arg" >&2; usage 2 ;;
    *)
      if [[ -n "$boris_arg" ]]; then
        echo "unexpected extra argument: $arg" >&2
        usage 2
      fi
      boris_arg="$arg"
      ;;
  esac
done
[[ -n "$boris_arg" ]] || usage 2

if [[ -d "$(dirname "$boris_arg")" ]]; then
  boris_bin="$(cd "$(dirname "$boris_arg")" && pwd)/$(basename "$boris_arg")"
else
  boris_bin="$boris_arg"
fi

# The black-box stages below consume the product binary as an external
# prerequisite: it must exist and answer --version with a boris/<x.y.z> id.
[[ -x "$boris_bin" ]] || {
  fail "boris binary not executable: $boris_bin"
  emit_summary false 0 "boris binary not executable: $boris_bin"
  exit 1
}
version="$( "$boris_bin" --version 2>/dev/null )" || {
  fail "boris --version failed for $boris_bin"
  emit_summary false 0 "boris --version failed"
  exit 1
}
case "$version" in
  boris/[0-9]*.[0-9]*.[0-9]*) ;;
  *)
    fail "unexpected boris --version output: '$version'"
    emit_summary false 0 "unexpected boris --version output"
    exit 1
    ;;
esac
GATE_BORIS="$version"
pass "boris binary: $boris_bin -> $version"

if [[ "$deps" == "1" ]]; then
  run_stage "install UI dependencies (npm ci + Playwright Chromium)" install_ui_deps
elif [[ ! -d editor/ui/node_modules ]]; then
  fail "editor/ui/node_modules is missing; run with --deps first"
  emit_summary false 0 "editor/ui/node_modules missing (run with --deps)"
  exit 1
fi

run_stage "editor format" zig fmt --check editor/build.zig editor/build.zig.zon editor/src
run_stage "editor host unit tests" zig build --build-file editor/build.zig test
run_stage "editor UI static checks (svelte-check + key hints)" npm --prefix editor/ui run check
run_stage "editor UI build" npm --prefix editor/ui run build
run_stage "editor host build (boris-editor + contract probe)" build_host_binaries
run_stage "editor UI end-to-end suite (Playwright, mocked host)" npm --prefix editor/ui run test:e2e

editor_bin="$root/editor/zig-out/bin/boris-editor"
probe_bin="$root/editor/zig-out/bin/boris-editor-contract-probe"
ui_dir="$root/editor/ui/dist"
run_stage "live integration: contract fixture" ./editor/scripts/test-contract-fixture.sh "$boris_bin" "$probe_bin"
run_stage "live integration: host safe-editing" ./editor/scripts/test-host.sh "$boris_bin" "$editor_bin" "$ui_dir"
run_stage "live integration: diagnostics" ./editor/scripts/test-diagnostics.sh "$boris_bin" "$editor_bin" "$ui_dir"
run_stage "live integration: validation daemon" ./editor/scripts/test-validation-daemon.sh "$boris_bin" "$editor_bin" "$ui_dir"
run_stage "live integration: live preview" ./editor/scripts/test-preview.sh "$boris_bin" "$editor_bin" "$ui_dir"
run_stage "live integration: publication" ./editor/scripts/test-publication.sh "$boris_bin" "$editor_bin" "$ui_dir"

printf '\neditor gate: PASSED against %s\n' "$version"
emit_summary true "$total_ms"
