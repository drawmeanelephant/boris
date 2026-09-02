# Shared runner for one-shot gate scripts. Sourced (not executed) by each gate
# (editor/scripts/test-editor-gate.sh, scripts/gate-standalone-tools.sh,
# scripts/gate-content-audit.sh, scripts/gate-release-html-smoke.sh), which
# then defines its stages with run_stage and ends every outcome with
# emit_summary. Requires bash 3.2+ (macOS /bin/bash).
#
# Machine-readable contract: every gate ends with exactly one line on stdout,
# last:
#
#   {"event":"<GATE_EVENT>","ok":true|false, ...}
#
# with per-stage {"stage":…,"ok":…,"ms":…} entries (or a "reason" object for
# guard failures), so logs and dashboards can tail -1 and parse the result.
# scripts/gate-summary.mjs renders that line as the GitHub job summary, and
# the CI lanes upload log + NDJSON line as an artifact.

note() { printf '\n==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; }

# Epoch milliseconds. GNU date can answer directly; elsewhere fall back to
# perl's core Time::HiRes (ships with macOS and Linux), then whole seconds.
now_ms() {
  local ns
  ns="$(date +%s%N 2>/dev/null)" || ns=""
  if [[ "$ns" =~ ^[0-9]{16,}$ ]]; then
    printf '%s' "${ns:0:13}"
    return
  fi
  perl -MTime::HiRes=time -e 'printf "%.0f\n", time()*1000' 2>/dev/null \
    || date +%s000
}

# Per-gate state. GATE_EVENT (e.g. "editor-gate") and optionally GATE_BORIS
# are set by the sourcing script before the first emit_summary call.
stage_results=()
total_ms=0

# The single trailing machine-readable summary line. $1 = ok (true|false),
# $2 = total_ms, $3 = optional failure reason (used when no stages ran).
emit_summary() {
  local ok="$1" total="$2" reason="${3:-}" out="" i
  out="{\"event\":\"${GATE_EVENT}\",\"ok\":$ok"
  if [[ -n "${GATE_BORIS:-}" ]]; then
    out="$out,\"boris\":\"$GATE_BORIS\""
  fi
  if [[ -n "$reason" ]]; then
    out="$out,\"reason\":\"$reason\""
  else
    out="$out,\"total_ms\":$total,\"stages\":["
    for ((i = 0; i < ${#stage_results[@]}; i++)); do
      [[ $i -gt 0 ]] && out="$out,"
      out="$out${stage_results[$i]}"
    done
    out="$out]"
  fi
  printf '%s\n' "$out}"
}

# Run one gated stage: banner, timing, result recording, and on failure a
# machine-readable summary before exiting nonzero.
run_stage() {
  local label="$1" rc start elapsed
  shift
  note "$label"
  start="$(now_ms)"
  set +e
  "$@"
  rc=$?
  set -e
  elapsed=$(( $(now_ms) - start ))
  if [[ $rc -eq 0 ]]; then
    pass "$label"
  else
    fail "$label (exit $rc)"
    total_ms=$(( total_ms + elapsed ))
    stage_results+=("{\"stage\":\"$label\",\"ok\":false,\"ms\":$elapsed}")
    emit_summary false "$total_ms"
    exit 1
  fi
  total_ms=$(( total_ms + elapsed ))
  stage_results+=("{\"stage\":\"$label\",\"ok\":true,\"ms\":$elapsed}")
}
