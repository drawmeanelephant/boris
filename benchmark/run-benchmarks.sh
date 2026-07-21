#!/usr/bin/env bash
set -uo pipefail

usage() {
  cat <<'USAGE'
Usage: benchmark/run-benchmarks.sh [--env FILE] [--runs N] setup|run

setup executes BENCHMARK_SETUP_COMMAND, if configured, and exits. run performs
the configured A-D matrix (10 repetitions by default).
USAGE
}

ENV_FILE="${BENCHMARK_ENV_FILE:-benchmark/environment.txt}"
RUNS=10
ACTION=""
while (($#)); do
  case "$1" in
    --env) [[ $# -ge 2 ]] || { echo "--env requires a file" >&2; exit 2; }; ENV_FILE=$2; shift 2 ;;
    --runs) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || { echo "--runs requires a positive integer" >&2; exit 2; }; RUNS=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    setup|run) [[ -z "$ACTION" ]] || { echo "choose setup or run once" >&2; exit 2; }; ACTION=$1; shift ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done
[[ -n "$ACTION" ]] || { usage >&2; exit 2; }
[[ -f "$ENV_FILE" ]] || { echo "configuration not found: $ENV_FILE (copy the template and fill every value)" >&2; exit 2; }

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

required() { [[ -n "${!1:-}" ]] || { echo "missing configuration: $1" >&2; exit 2; }; }
value() { printf '%s' "${!1:-}"; }
required FILED_SOURCE_DIR
required BENCHMARK_ROOT
required BENCHMARK_IMPLEMENTATIONS
[[ -d "$FILED_SOURCE_DIR" ]] || { echo "source directory not found: $FILED_SOURCE_DIR" >&2; exit 2; }
mkdir -p "$BENCHMARK_ROOT/raw"

if [[ "$ACTION" == setup ]]; then
  if [[ -z "${BENCHMARK_SETUP_COMMAND:-}" ]]; then
    echo "setup: no BENCHMARK_SETUP_COMMAND configured; nothing measured or installed"
    exit 0
  fi
  echo "setup: executing configured install/checkout command (not measured)"
  bash -lc "$BENCHMARK_SETUP_COMMAND"
  exit $?
fi

for impl in $BENCHMARK_IMPLEMENTATIONS; do
  prefix=$(printf '%s' "$impl" | tr '[:lower:]-' '[:upper:]_')
  required "${prefix}_DIR"
  required "${prefix}_REF"
  dir=$(value "${prefix}_DIR")
  [[ -d "$dir/.git" || -f "$dir/.git" ]] || { echo "$impl: not a git checkout: $dir" >&2; exit 2; }
  actual=$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)
  ref=$(value "${prefix}_REF")
  expected=$(git -C "$dir" rev-parse "$ref^{commit}" 2>/dev/null || true)
  [[ -n "$actual" && "$actual" == "$expected" ]] || { echo "$impl: checkout is not exact ref $ref (actual $actual, expected $expected)" >&2; exit 2; }
done

for scenario in A B C D; do
  for impl in $BENCHMARK_IMPLEMENTATIONS; do
    prefix=$(printf '%s' "$impl" | tr '[:lower:]-' '[:upper:]_')
    required "${prefix}_${scenario}_COMMAND"
    required "${prefix}_${scenario}_SOURCE_DIR"
  done
done

timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
manifest="$BENCHMARK_ROOT/environment-$timestamp.txt"
{
  echo "timestamp_utc=$timestamp"
  echo "host=$(uname -a)"
  echo "shell=$BASH_VERSION"
  echo "runs=$RUNS"
  echo "implementations=$BENCHMARK_IMPLEMENTATIONS"
  for impl in $BENCHMARK_IMPLEMENTATIONS; do
    prefix=$(printf '%s' "$impl" | tr '[:lower:]-' '[:upper:]_')
    dir=$(value "${prefix}_DIR")
    echo "$impl.checkout=$dir"
    echo "$impl.ref=$(value "${prefix}_REF")"
    echo "$impl.commit=$(git -C "$dir" rev-parse HEAD)"
    echo "$impl.status=$(git -C "$dir" status --porcelain=v1)"
    if [[ -f "$dir/package.json" ]]; then
      echo "$impl.package_json_sha256=$(shasum -a 256 "$dir/package.json" | awk '{print $1}')"
      echo "$impl.astro_dependency=$(rg -o '"astro"[[:space:]]*:[[:space:]]*"[^"]+"' "$dir/package.json" | head -1 || true)"
    fi
  done
} > "$manifest"
echo "environment manifest: $manifest"

file_count_bytes() {
  local dir=$1 count bytes
  count=$(find "$dir" -type f -print 2>/dev/null | wc -l | awk '{print $1}')
  if stat -c '%s' "$dir" >/dev/null 2>&1; then
    bytes=$(find "$dir" -type f -exec stat -c '%s' {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
  else
    bytes=$(find "$dir" -type f -exec stat -f '%z' {} + 2>/dev/null | awk '{s+=$1} END {print s+0}')
  fi
  printf '%s\t%s' "$count" "$bytes"
}

time_args=(-f '%e %M')
time_has_rss=1
if [[ "$(uname -s)" == Darwin ]]; then
  time_args=(-l)
  time_has_rss=1
  if ! /usr/bin/time -l -o "$BENCHMARK_ROOT/.time-probe" true 2>/dev/null; then
    # Sandboxed macOS hosts may deny the RSS sysctl used by -l. Keep timing
    # valid and make the missing peak-RSS field explicit instead of failing a
    # product build for a host measurement limitation.
    time_args=(-p)
    time_has_rss=0
  fi
  rm -f "$BENCHMARK_ROOT/.time-probe"
fi
results="$BENCHMARK_ROOT/results.tsv"
printf 'timestamp_utc\timplementation\tscenario\trepetition\texit_code\telapsed_seconds\tpeak_rss_kb\toutput_files\toutput_bytes\traw_stdout\traw_stderr\n' > "$results"

for scenario in A B C D; do
  for impl in $BENCHMARK_IMPLEMENTATIONS; do
    prefix=$(printf '%s' "$impl" | tr '[:lower:]-' '[:upper:]_')
    dir=$(value "${prefix}_DIR")
    source=$(value "${prefix}_${scenario}_SOURCE_DIR")
    output="$BENCHMARK_ROOT/work/$impl/$scenario/output"
    cache="$BENCHMARK_ROOT/work/$impl/$scenario/cache"
    work="$BENCHMARK_ROOT/work/$impl/$scenario"
    mkdir -p "$work"
    rm -rf "$output" "$cache"
    export BENCHMARK_SOURCE_DIR="$source" BENCHMARK_OUTPUT_DIR="$output" BENCHMARK_CACHE_DIR="$cache" BENCHMARK_RUN_DIR="$work"
    for ((rep=1; rep<=RUNS; rep++)); do
      if [[ "$scenario" == A || "$rep" == 1 ]]; then rm -rf "$output" "$cache"; fi
      if [[ "$scenario" == D ]]; then
        required "${prefix}_D_BASELINE_COMMAND"
        required "${prefix}_D_EDIT_COMMAND"
        baseline_cmd=$(value "${prefix}_D_BASELINE_COMMAND")
        edit_cmd=$(value "${prefix}_D_EDIT_COMMAND")
        bash -lc "$baseline_cmd" >"$work/baseline-$rep.stdout" 2>"$work/baseline-$rep.stderr" || { echo "$impl D baseline failed at repetition $rep" >&2; exit 1; }
        bash -lc "$edit_cmd" >"$work/edit-$rep.stdout" 2>"$work/edit-$rep.stderr" || { echo "$impl D edit failed at repetition $rep" >&2; exit 1; }
      fi
      stdout="$BENCHMARK_ROOT/raw/${impl}-${scenario}-${rep}.stdout"
      stderr="$BENCHMARK_ROOT/raw/${impl}-${scenario}-${rep}.stderr"
      timing="$work/time-$rep.txt"
      command=$(value "${prefix}_${scenario}_COMMAND")
      /usr/bin/time "${time_args[@]}" -o "$timing" bash -lc "$command" >"$stdout" 2>"$stderr"
      code=$?
      if [[ "$(uname -s)" == Darwin ]]; then
        elapsed=$(awk '$1=="real" {print $2}' "$timing" | tail -1)
        if [[ $time_has_rss -eq 1 ]]; then rss=$(awk '/maximum resident set size/ {print $1/1024}' "$timing" | tail -1); else rss=NA; fi
      else
        read -r elapsed rss < "$timing" || true
      fi
      [[ -n "$elapsed" ]] || elapsed=NA
      [[ -n "$rss" ]] || rss=NA
      if [[ -d "$output" ]]; then read -r files bytes < <(file_count_bytes "$output"); else files=0; bytes=0; fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$impl" "$scenario" "$rep" "$code" "$elapsed" "$rss" "$files" "$bytes" "$stdout" "$stderr" >> "$results"
      [[ $code -eq 0 ]] || { echo "$impl scenario $scenario repetition $rep failed (exit $code); raw stderr: $stderr" >&2; exit 1; }
    done
  done
done
echo "completed: $results"
