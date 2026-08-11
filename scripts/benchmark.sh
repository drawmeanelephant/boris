#!/usr/bin/env bash
# Boris ReleaseFast HTML benchmark + regression gate (PERF-028).
#
# Invoked by `zig build benchmark`. The boris binary passed as "$1" is the
# ReleaseFast build — the build step forces -Doptimize=ReleaseFast for it — so
# measured numbers can never be confused with Debug timings (PERF-030).
#
# Flow:
#   1. Generate the pinned deterministic corpus (default 1000 pages) below
#      tools/testdata-generator/.generated (owned by this script).
#   2. Run boris --timings --quiet over it (ReleaseFast binary from the build step).
#   3. Parse the machine-readable "boris-timings {...}" stderr line.
#   4. Compare every measured phase against the checked-in baseline multiplied
#      by BORIS_BENCHMARK_FACTOR (default 2.0). A deliberate regression fails.
#
# Environment:
#   BORIS_BENCHMARK_PAGES            corpus size (default 1000; start CI at 1k)
#   BORIS_BENCHMARK_FACTOR           gate multiplier (default 2.0; use 0.0001 to
#                                    force failure and prove the gate fires)
#   BORIS_BENCHMARK_JOBS             boris --jobs (default 1)
#   BORIS_BENCHMARK_BASELINE         baseline JSON (default tools/testdata-generator/baseline/benchmark-1k.json)
#   BORIS_BENCHMARK_UPDATE_BASELINE  rewrite the baseline from this run (1; maintainers)
#   BORIS_BENCHMARK_KEEP             keep the generated corpus for inspection (1)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BORIS="${1:-./zig-out/bin/boris}"
PAGES="${BORIS_BENCHMARK_PAGES:-1000}"
FACTOR="${BORIS_BENCHMARK_FACTOR:-2.0}"
JOBS="${BORIS_BENCHMARK_JOBS:-1}"
BASELINE="${BORIS_BENCHMARK_BASELINE:-tools/testdata-generator/baseline/benchmark-1k.json}"
CORPUS="tools/testdata-generator/.generated"
STDERR="${CORPUS}/boris-stderr.txt"
TIMINGS_JSON="${CORPUS}/timings.json"

command -v python3 >/dev/null || { echo "benchmark: python3 is required to parse the timings JSON"; exit 1; }
command -v zig >/dev/null || { echo "benchmark: zig is required to generate the corpus"; exit 1; }

cleanup() {
  if [[ "${BORIS_BENCHMARK_KEEP:-}" != "1" ]]; then
    rm -rf "${CORPUS}"
  fi
}
trap cleanup EXIT

echo "==> benchmark: ReleaseFast boris binary: ${BORIS}"
echo "==> benchmark: corpus pages=${PAGES} jobs=${JOBS} factor=${FACTOR} baseline=${BASELINE}"

# 1. Deterministic corpus.
echo "==> benchmark: generating pinned corpus (${PAGES} pages)"
zig run tools/testdata-generator/main.zig -- --pages "${PAGES}" --out "${CORPUS}" >/dev/null

# 2. Time a cold ReleaseFast HTML build with --timings (--quiet keeps stderr
#    dedicated to the timing report).
echo "==> benchmark: running ${BORIS} over the corpus"
"${BORIS}" \
  --input "${CORPUS}/content" \
  --html-dir "${CORPUS}/dist" \
  --html-layout "${CORPUS}/layouts/main.html" \
  --timings --quiet --jobs "${JOBS}" \
  2>"${STDERR}"

if ! grep -q '^boris-timings ' "${STDERR}"; then
  echo "benchmark: FAIL — no 'boris-timings' line on stderr; cannot measure"
  sed -n '1,20p' "${STDERR}"
  exit 1
fi
grep '^boris-timings ' "${STDERR}" | sed 's/^boris-timings //' > "${TIMINGS_JSON}"

# 3+4. Compare against the baseline with the generous factor; fail hard on
#      regressions, missing phases, or unparseable output.
python3 - "${BASELINE}" "${TIMINGS_JSON}" "${FACTOR}" <<'PY'
import json, sys

baseline_path, measured_path, factor = sys.argv[1], sys.argv[2], float(sys.argv[3])
with open(baseline_path) as f:
    baseline = json.load(f)
with open(measured_path) as f:
    measured = json.load(f)

b_phases = baseline.get("phases", {})
m_phases = measured.get("phases", {})
if not m_phases:
    print("benchmark: FAIL — measured timings object has no phases")
    sys.exit(1)

print("benchmark: phase table (ms, limit = baseline * %.2f):" % factor)
failures = []
for name in sorted(b_phases):
    base_ns = b_phases[name]
    if name not in m_phases:
        failures.append(f"{name}: MISSING from measured output")
        continue
    got_ns = m_phases[name]
    limit_ns = base_ns * factor
    ok = got_ns <= limit_ns
    print("  %-22s %10.3f  (limit %10.3f)  %s" % (
        name, got_ns / 1e6, limit_ns / 1e6, "ok" if ok else "FAIL"))
    if not ok:
        failures.append(f"{name}: {got_ns / 1e6:.3f} ms > limit {limit_ns / 1e6:.3f} ms")

if failures:
    print("benchmark: FAIL — %d phase(s) exceeded the baseline bound" % len(failures))
    for f in failures:
        print("  " + f)
    sys.exit(1)

counters = measured.get("counters", {})
print("benchmark: counters:", json.dumps(counters, sort_keys=True))
print("benchmark: PASS — no phase exceeded %.2fx baseline" % factor)
PY

# Optional: refresh the checked-in baseline (maintainer action, never on CI).
if [[ "${BORIS_BENCHMARK_UPDATE_BASELINE:-}" == "1" ]]; then
  python3 - "${BASELINE}" "${TIMINGS_JSON}" <<'PY'
import json, sys
baseline_path, measured_path = sys.argv[1], sys.argv[2]
with open(baseline_path) as f:
    baseline = json.load(f)
with open(measured_path) as f:
    measured = json.load(f)
baseline["phases"] = {k: int(v) for k, v in measured.get("phases", {}).items()}
with open(baseline_path, "w") as f:
    json.dump(baseline, f, indent=2, sort_keys=True)
    f.write("\n")
print(f"benchmark: baseline updated at {baseline_path}")
PY
fi
