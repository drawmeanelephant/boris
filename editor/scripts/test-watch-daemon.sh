#!/usr/bin/env bash
set -euo pipefail

# Host integration for the managed `boris watch --watch-json` daemon
# (editor watch-admin slice):
#   - one explicitly started `boris watch --input content --html-dir dist
#     --watch-json` process per project; a second start is idempotent;
#   - the daemon's contracted NDJSON event stream (§8) is captured and served
#     with monotonically increasing `seq` numbers via /api/watch/events;
#   - /api/watch/state uses the same honest-state naming as
#     /api/validate-state (idle → running → success/failed, stale on death);
#   - while the watch daemon owns the dist/ writer seat, /api/preview/rebuild
#     is refused with a distinct state; stopping re-enables rebuild;
#   - the validation daemon coexists with the watch daemon (write-disjoint);
#   - a kill -9'd daemon is reaped and recovered with bounded backoff;
#   - POST /api/watch/stop SIGTERM-reaps the daemon (no orphan), as does
#     SIGTERM to the editor itself.
#
# When the installed compiler does not advertise `--watch-json`, the host must
# refuse to start the daemon honestly; this script skips (the one-shot paths
# are covered by the other integration scripts).

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BORIS_BIN EDITOR_BIN UI_DIR" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
editor_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ui_dir="$(cd "$3" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-watch.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$boris_bin" init "$work/project" >/dev/null

# The managed daemon is only offered when the compiler accepts `watch
# --watch-json` (§8). Older compilers get honest unsupported states instead.
if ! "$boris_bin" watch --help 2>&1 | grep -q -- '--watch-json'; then
  echo "compiler does not advertise watch --watch-json; skipping watch-daemon integration" >&2
  exit 0
fi

"$editor_bin" "$work/project" --boris "$boris_bin" --ui-dir "$ui_dir" --port 0 >"$work/host.log" 2>&1 &
editor_pid=$!
for _ in $(seq 1 100); do
  grep -q 'BORIS_EDITOR_URL=' "$work/host.log" && break
  kill -0 "$editor_pid" 2>/dev/null || { sed -n '1,120p' "$work/host.log" >&2; exit 1; }
  sleep 0.05
done
launch_url="$(sed -n 's/^BORIS_EDITOR_URL=//p' "$work/host.log" | head -1)"
[[ -n "$launch_url" ]]
base_url="${launch_url%%/#*}"
token="${launch_url##*#token=}"
port="$(printf '%s' "$base_url" | sed -E 's#.*:([0-9]+)$#\1#')"

get_api() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    "$base_url$2" >"$1"
}

post_api() {
  curl --fail --silent --show-error \
    -X POST \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    -H 'Content-Type: application/json' \
    --data '{}' "$base_url$2" >"$1"
}

post_api_code() {
  # Prints the HTTP status code; response body written to $1.
  curl --silent --show-error --output "$1" --write-out '%{http_code}' \
    -X POST \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    -H 'Content-Type: application/json' \
    --data '{}' "$base_url$2"
}

watch_state_field() {
  node -e 'const s = JSON.parse(require("fs").readFileSync(0)); console.log(s[process.argv[1]]);' "$1" <"$2"
}

watch_pids() {
  pgrep -f "watch --input content --html-dir dist --watch-json" 2>/dev/null || true
}

watch_count() {
  watch_pids | wc -l | tr -d ' '
}

validate_pids() {
  pgrep -f "validate --input content --report \.boris/html-build-report\.json --watch" 2>/dev/null || true
}

# The host advertises the managed daemon when the compiler accepts the stream.
get_api "$work/version.json" '/api/version'
node -e 'const v = require(process.argv[1]); if (!v.supported || v.supported.watch_json !== true) throw Error("watch_json not advertised");' "$work/version.json"

# Before any start the state is honestly idle: nothing spawned, nothing seen.
get_api "$work/state-idle.json" '/api/watch/state'
node -e '
  const s = require(process.argv[1]);
  if (s.supported !== true || s.state !== "idle") throw Error("pre-start state not idle: " + JSON.stringify(s));
  if (s.seq !== 0 || s.cycle !== 0 || s.events_count !== 0) throw Error("pre-start counters not empty: " + JSON.stringify(s));
' "$work/state-idle.json"
[[ "$(watch_count)" == "0" ]] || { echo "watch daemon spawned without an explicit start" >&2; exit 1; }

# Endpoints are authenticated like every other endpoint: no token, no state.
curl --silent --show-error --output "$work/unauthorized.json" --write-out '%{http_code}' \
  -H "Host: 127.0.0.1:$port" "$base_url/api/watch/state" >"$work/unauthorized.code"
[[ "$(cat "$work/unauthorized.code")" == "403" ]] || { echo "unauthenticated watch/state was not refused" >&2; exit 1; }

# Explicit start: exactly one daemon; a second start is idempotent.
post_api "$work/start.json" '/api/watch/start'
node -e 'const s = require(process.argv[1]); if (s.status !== "started" || s.state.supported !== true || s.state.state !== "running") throw Error("start did not report a running daemon: " + JSON.stringify(s));' "$work/start.json"
for _ in $(seq 1 50); do
  [[ "$(watch_count)" == "1" ]] && break
  sleep 0.1
done
[[ "$(watch_count)" == "1" ]] || { echo "expected exactly one watch daemon after start, found $(watch_count)" >&2; exit 1; }
post_api "$work/start-again.json" '/api/watch/start'
node -e 'const s = require(process.argv[1]); if (s.status !== "already-running") throw Error("second start not idempotent: " + JSON.stringify(s));' "$work/start-again.json"
[[ "$(watch_count)" == "1" ]] || { echo "second start spawned a second daemon" >&2; exit 1; }

# The contracted event stream (§8) is captured with strictly increasing seq:
# hello → build-started → build-succeeded(initial) → watcher-started.
seq_seen=0
succeeded=""
for _ in $(seq 1 150); do
  get_api "$work/events.json" "/api/watch/events?after=$seq_seen"
  read -r seq_seen succeeded < <(node -e '
    const s = require(process.argv[1]);
    let latest = Number(process.argv[2]);
    let ok = "";
    for (const entry of s.events) {
      if (typeof entry.seq !== "number" || entry.seq <= latest) throw Error("seq not strictly increasing");
      latest = entry.seq;
      const e = entry.event;
      if (e.event === "hello") {
        if (e.watch_events_schema !== 1 || !/^boris\//.test(e.compiler)) throw Error("hello handshake mismatch: " + JSON.stringify(e));
      }
      if (e.event === "build-succeeded" && e.phase === "initial" && e.mode === "html") {
        if (!Array.isArray(e.targets) || e.targets[0] !== "default") throw Error("targets mismatch: " + JSON.stringify(e));
        if (typeof e.pages_written !== "number" || typeof e.duration_ms !== "number") throw Error("build-succeeded fields missing: " + JSON.stringify(e));
        ok = "initial";
      }
    }
    if (s.gap !== false) throw Error("unexpected gap on a fresh buffer");
    console.log(latest, ok);
  ' "$work/events.json" "$seq_seen")
  [[ -n "$succeeded" ]] && break
  sleep 0.2
done
[[ -n "$succeeded" ]] || { echo "initial build-succeeded event never captured" >&2; exit 1; }
get_api "$work/state-initial.json" '/api/watch/state'
node -e '
  const s = require(process.argv[1]);
  if (s.state !== "success" || s.cycle !== 1) throw Error("state after initial build not success: " + JSON.stringify(s));
  if (typeof s.compiler_id !== "string" || !s.compiler_id.startsWith("boris/")) throw Error("compiler_id not captured from hello: " + JSON.stringify(s));
  if (s.last_event === null || s.last_event.event !== "watcher-started") throw Error("last_event summary missing: " + JSON.stringify(s));
' "$work/state-initial.json"

# Dist-writer mutual exclusion: while the watch daemon runs, preview rebuild
# is refused with a distinct honest state.
code="$(post_api_code "$work/rebuild-refused.json" '/api/preview/rebuild')"
[[ "$code" == "409" ]] || { echo "preview rebuild during watch was not refused (got $code)" >&2; exit 1; }
node -e 'const s = require(process.argv[1]); if (s.error !== "watch_daemon_active") throw Error("rebuild refusal not watch_daemon_active: " + JSON.stringify(s));' "$work/rebuild-refused.json"
get_api "$work/preview-during.json" '/api/preview/state'
node -e 'const s = require(process.argv[1]); if (s.watch_active !== true) throw Error("preview state does not report the active watch daemon");' "$work/preview-during.json"

# Coexistence: the zero-write validation daemon and the watch daemon are
# write-disjoint (the report file lives under .boris/, which the watch loop
# ignores), so both run concurrently and neither replaces the other.
curl --fail --silent --show-error -X POST \
  -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" -H 'Content-Type: application/json' \
  --data '{"mode":"validate"}' "$base_url/api/commands/run" >"$work/validate.json"
node -e 'const r = require(process.argv[1]); if (r.exit_code !== 0 || r.failure_class !== "success") throw Error("validate during watch failed: " + JSON.stringify(r));' "$work/validate.json"
for _ in $(seq 1 50); do
  [[ "$(validate_pids | wc -l | tr -d ' ')" == "1" ]] && break
  sleep 0.1
done
[[ "$(validate_pids | wc -l | tr -d ' ')" == "1" ]] || { echo "validation daemon did not run alongside the watch daemon" >&2; exit 1; }
[[ "$(watch_count)" == "1" ]] || { echo "watch daemon vanished during coexistence" >&2; exit 1; }
sleep 1
[[ "$(watch_count)" == "1" ]] || { echo "watch daemon disturbed by validation report writes" >&2; exit 1; }
get_api "$work/state-coexist.json" '/api/watch/state'
node -e 'const s = require(process.argv[1]); if (s.state === "failed") throw Error("watch daemon failed after validation coexistence: " + JSON.stringify(s));' "$work/state-coexist.json"

# Break content: the daemon rebuilds on its own debounce, emits build-failed
# with structured diagnostics, and the state names the failure honestly.
cp "$repo_root/fixtures/content/invalid/duplicate-id/a.md" "$work/project/content/a.md"
cp "$repo_root/fixtures/content/invalid/duplicate-id/b.md" "$work/project/content/b.md"
failed_seq=""
for _ in $(seq 1 150); do
  get_api "$work/state-failed.json" '/api/watch/state'
  state="$(watch_state_field state "$work/state-failed.json")"
  if [[ "$state" == "failed" ]]; then
    failed_seq="$(watch_state_field seq "$work/state-failed.json")"
    break
  fi
  sleep 0.2
done
[[ -n "$failed_seq" ]] || { echo "watch daemon never reported the broken build" >&2; exit 1; }
get_api "$work/events-failed.json" "/api/watch/events?after=$((failed_seq - 1))"
node -e '
  const s = require(process.argv[1]);
  const failed = s.events.map((x) => x.event).filter((e) => e.event === "build-failed").pop();
  if (!failed) throw Error("no build-failed event at the failed seq");
  if (failed.recoverable !== true) throw Error("content failure not marked recoverable");
  if (failed.mode !== "html" || failed.phase !== "rebuild") throw Error("build-failed phase/mode mismatch");
  if (!Array.isArray(failed.diagnostics) || failed.diagnostics.length === 0) throw Error("build-failed carried no diagnostics");
  if (failed.diagnostics[0].code !== "EDUPLICATEID") throw Error("expected EDUPLICATEID diagnostic: " + JSON.stringify(failed.diagnostics));
' "$work/events-failed.json"

# Fix content: recovery without a restart, with a rebuild event naming the
# changed paths.
rm "$work/project/content/a.md" "$work/project/content/b.md"
for _ in $(seq 1 150); do
  get_api "$work/state-recovered.json" '/api/watch/state'
  state="$(watch_state_field state "$work/state-recovered.json")"
  [[ "$state" == "success" ]] && break
  sleep 0.2
done
[[ "$state" == "success" ]] || { echo "watch daemon did not recover after the fix" >&2; exit 1; }
recovered_seq="$(watch_state_field seq "$work/state-recovered.json")"
get_api "$work/events-recovered.json" "/api/watch/events?after=$((recovered_seq - 1))"
node -e '
  const s = require(process.argv[1]);
  const ok = s.events.map((x) => x.event).filter((e) => e.event === "build-succeeded" && e.phase === "rebuild").pop();
  if (!ok) throw Error("no rebuild build-succeeded event after the fix");
  if (!Array.isArray(ok.changed) || ok.changed.length === 0) throw Error("rebuild event carried no changed paths");
' "$work/events-recovered.json"

# Unexpected death: the next supervised request reaps the corpse (stale) and
# a later one restarts exactly one daemon after the bounded backoff, with the
# sequence numbers continuing to advance across the restart.
seq_before_death="$recovered_seq"
kill -9 "$(watch_pids | head -1)" 2>/dev/null || true
get_api "$work/state-dead.json" '/api/watch/state'
dead_state="$(watch_state_field state "$work/state-dead.json")"
case "$dead_state" in
  stale | running | success) : ;; # stale within the backoff window; already restarted if slow
  *) echo "unexpected state after kill -9: $dead_state" >&2; exit 1 ;;
esac
recovered=""
for _ in $(seq 1 150); do
  get_api "$work/state-restart.json" '/api/watch/state'
  state="$(watch_state_field state "$work/state-restart.json")"
  restart_seq="$(watch_state_field seq "$work/state-restart.json")"
  if [[ "$state" == "success" || "$state" == "running" ]] && [[ "$restart_seq" -gt "$seq_before_death" ]]; then
    recovered=1
    break
  fi
  sleep 0.2
done
[[ -n "$recovered" ]] || { echo "watch daemon did not recover after kill -9" >&2; exit 1; }
for _ in $(seq 1 50); do
  [[ "$(watch_count)" == "1" ]] && break
  sleep 0.1
done
[[ "$(watch_count)" == "1" ]] || { echo "expected exactly one daemon after restart, found $(watch_count)" >&2; exit 1; }
get_api "$work/events-restart.json" "/api/watch/events?after=$seq_before_death"
node -e '
  const s = require(process.argv[1]);
  const events = s.events.map((x) => x.event.event);
  if (!events.includes("hello")) throw Error("restarted daemon did not re-handshake with hello: " + JSON.stringify(events));
' "$work/events-restart.json"

# Explicit stop: graceful SIGTERM + reap, no orphan, honest idle state, and
# the dist/ writer seat returns to the preview rebuild path.
post_api "$work/stop.json" '/api/watch/stop'
node -e 'const s = require(process.argv[1]); if (s.status !== "stopped" || s.state.state !== "idle") throw Error("stop did not park the daemon: " + JSON.stringify(s));' "$work/stop.json"
for _ in $(seq 1 50); do
  [[ "$(watch_count)" == "0" ]] && break
  sleep 0.1
done
[[ "$(watch_count)" == "0" ]] || { echo "orphaned watch daemon survived an explicit stop" >&2; exit 1; }
get_api "$work/preview-after.json" '/api/preview/state'
node -e 'const s = require(process.argv[1]); if (s.watch_active !== false) throw Error("preview state still reports an active watch daemon after stop");' "$work/preview-after.json"
post_api "$work/rebuild-after.json" '/api/preview/rebuild'
node -e 'const s = require(process.argv[1]); if (s.phase !== "success") throw Error("preview rebuild not re-enabled after stop: " + JSON.stringify(s));' "$work/rebuild-after.json"
post_api "$work/stop-again.json" '/api/watch/stop'
node -e 'const s = require(process.argv[1]); if (s.status !== "not-running") throw Error("second stop not idempotent: " + JSON.stringify(s));' "$work/stop-again.json"

# SIGTERM to the editor with a running daemon must reap it (no orphan).
post_api "$work/restart-before-shutdown.json" '/api/watch/start'
node -e 'const s = require(process.argv[1]); if (s.status !== "started") throw Error("restart before shutdown failed: " + JSON.stringify(s));' "$work/restart-before-shutdown.json"
for _ in $(seq 1 50); do
  [[ "$(watch_count)" == "1" ]] && break
  sleep 0.1
done
kill "$editor_pid" 2>/dev/null || true
wait "$editor_pid" 2>/dev/null
editor_exit=$?
editor_pid=""
[[ "$editor_exit" == "0" ]] || { echo "editor SIGTERM exit $editor_exit (expected 0)" >&2; exit 1; }
for _ in $(seq 1 50); do
  [[ "$(watch_count)" == "0" ]] && break
  sleep 0.1
done
[[ "$(watch_count)" == "0" ]] || { echo "orphaned watch daemon survived editor shutdown" >&2; exit 1; }

echo "editor watch daemon integration: ok"
