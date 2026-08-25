#!/usr/bin/env bash
set -euo pipefail

# Host integration for the long-lived validation daemon (#652):
#   - one `boris validate --watch --report` process per project (no per-request
#     one-shot spawn on the validate path);
#   - save → daemon rewrites the report → state cycle advances → validate
#     reflects ok → failed → ok without a host restart;
#   - a validate demand right after a host file op (save/create/rename/delete)
#     answers from AFTER the change, waiting for the pending daemon cycle
#     instead of serving the pre-save cached result (#656);
#   - an unexpected daemon death is reaped and recovered with bounded backoff;
#   - SIGTERM on the editor reaps the daemon (no orphan process).
#
# When the installed compiler does not advertise `validate --watch`, the host
# must fall back to the one-shot path; that is covered by test-diagnostics.sh,
# and this script skips (the fallback is the byte-identical one-shot runner).

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BORIS_BIN EDITOR_BIN UI_DIR" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
editor_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ui_dir="$(cd "$3" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-daemon.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$boris_bin" init "$work/project" >/dev/null

# The daemon path is only taken when the compiler accepts `validate --watch`.
if ! "$boris_bin" validate --help 2>&1 | grep -q -- '--watch'; then
  echo "compiler does not advertise validate --watch; skipping daemon integration" >&2
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

run_command() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    -H 'Content-Type: application/json' \
    --data "$2" "$base_url/api/commands/run" >"$1"
}

post_api() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    -H 'Content-Type: application/json' \
    --data "$3" "$base_url$2" >"$1"
}

get_api() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    "$base_url$2" >"$1"
}

state_cycle() {
  get_api "$work/state.json" '/api/validate-state'
  node -e 'const s = require(process.argv[1]); if (!s.supported || typeof s.cycle !== "number" || !(s.report_age_ms === null || typeof s.report_age_ms === "number")) throw Error("validate-state payload mismatch"); console.log(s.cycle);' "$work/state.json"
}

daemon_pids() {
  pgrep -f "boris validate --input content --report \.boris/html-build-report\.json --watch" 2>/dev/null || true
}

daemon_count() {
  daemon_pids | wc -l | tr -d ' '
}

# The host advertises daemon support when the compiler accepts --watch.
get_api "$work/version.json" '/api/version'
node -e 'const v = require(process.argv[1]); if (!v.supported || v.supported.validate_watch !== true) throw Error("validate_watch not advertised");' "$work/version.json"

# First validate demand starts exactly one daemon; the second demand reuses it,
# proving the per-request one-shot spawn is gone from the validate path.
run_command "$work/validate-1.json" '{"mode":"validate"}'
node -e '
  const r = require(process.argv[1]);
  if (r.exit_code !== 0 || r.failure_class !== "success" || r.report_version !== "html-build-report-0.2.0") throw Error("clean project did not validate through the daemon");
  if (r.used_stderr_fallback) throw Error("daemon result used stderr fallback");
' "$work/validate-1.json"
[[ "$(daemon_count)" == "1" ]] || { echo "expected exactly one validate --watch daemon, found $(daemon_count)" >&2; exit 1; }
run_command "$work/validate-2.json" '{"mode":"validate"}'
node -e 'const r = require(process.argv[1]); if (r.exit_code !== 0 || r.failure_class !== "success") throw Error("second validate failed");' "$work/validate-2.json"
[[ "$(daemon_count)" == "1" ]] || { echo "validate spawned a second daemon; expected one" >&2; exit 1; }

# Break content. The daemon rewrites the report on its own debounced cycle and
# the state cycle counter advances; validate then reports the failure.
cp "$repo_root/fixtures/content/invalid/duplicate-id/a.md" "$work/project/content/a.md"
cp "$repo_root/fixtures/content/invalid/duplicate-id/b.md" "$work/project/content/b.md"
cycle_before="$(state_cycle)"
failed_cycle=""
for _ in $(seq 1 100); do
  failed_cycle="$(state_cycle)"
  [[ "$failed_cycle" != "$cycle_before" ]] && break
  sleep 0.1
done
[[ "$failed_cycle" != "$cycle_before" ]] || { echo "daemon never rewrote the report after a content change" >&2; exit 1; }
run_command "$work/validate-failed.json" '{"mode":"validate"}'
node -e '
  const r = require(process.argv[1]);
  if (r.exit_code !== 1 || r.failure_class !== "content" || r.report_version !== "html-build-report-0.2.0") throw Error("daemon failure classification mismatch");
  if (!r.problems.some(p => p.code === "EDUPLICATEID")) throw Error("daemon report missing EDUPLICATEID");
  if (r.used_stderr_fallback) throw Error("daemon result used stderr fallback");
' "$work/validate-failed.json"

# Fix content: ok → failed → ok without a host restart.
rm "$work/project/content/a.md" "$work/project/content/b.md"
recovered_cycle=""
for _ in $(seq 1 100); do
  recovered_cycle="$(state_cycle)"
  [[ "$recovered_cycle" != "$failed_cycle" ]] && break
  sleep 0.1
done
[[ "$recovered_cycle" != "$failed_cycle" ]] || { echo "daemon did not recover after the fix" >&2; exit 1; }
run_command "$work/validate-recovered.json" '{"mode":"validate"}'
node -e 'const r = require(process.argv[1]); if (r.exit_code !== 0 || r.failure_class !== "success") throw Error("daemon did not recover");' "$work/validate-recovered.json"

# A18: a validate demand that arrives right after a host file op must answer
# from AFTER the change. The daemon's own cycle is still pending (its debounce
# has not rewritten the report yet), so runValidate waits for that cycle
# instead of serving the pre-save cached result. No cycle-wait loop, no state
# poll: the demand itself must come back with the new failure state.
#
# The duplicate-id pair is used because graph/content errors populate the
# report's diagnostics (frontmatter-only errors leave an empty report). First
# create b.md through the API and let its (clean) cycle settle, so the a.md
# create below is the only pending change when the demand lands.
create_file() { post_api "$1" /api/files/create "$2"; }
b_payload="$(node -e 'console.log(JSON.stringify({ path: "content/b.md", content: require("fs").readFileSync(process.argv[1], "utf8") }));' "$repo_root/fixtures/content/invalid/duplicate-id/b.md")"
a_payload="$(node -e 'console.log(JSON.stringify({ path: "content/a.md", content: require("fs").readFileSync(process.argv[1], "utf8") }));' "$repo_root/fixtures/content/invalid/duplicate-id/a.md")"
create_file "$work/created-b.json" "$b_payload"
node -e 'const r = require(process.argv[1]); if (r.status !== "created") throw Error("create b failed: " + r.status);' "$work/created-b.json"
settle_cycle_before="$(state_cycle)"
settled_b=""
for _ in $(seq 1 100); do
  settled_b="$(state_cycle)"
  [[ "$settled_b" != "$settle_cycle_before" ]] && break
  sleep 0.1
done
[[ "$settled_b" != "$settle_cycle_before" ]] || { echo "daemon never settled after creating b.md" >&2; exit 1; }
create_file "$work/created-a.json" "$a_payload"
node -e 'const r = require(process.argv[1]); if (r.status !== "created") throw Error("create a failed: " + r.status);' "$work/created-a.json"
run_command "$work/validate-post-create.json" '{"mode":"validate"}'
node -e '
  const r = require(process.argv[1]);
  if (r.exit_code !== 1 || r.failure_class !== "content") throw Error("immediate validate after create answered stale: exit " + r.exit_code + " / " + r.failure_class);
  if (!r.problems.some(p => p.code === "EDUPLICATEID")) throw Error("post-create report missing EDUPLICATEID");
  if (r.used_stderr_fallback) throw Error("post-create result used stderr fallback");
' "$work/validate-post-create.json"
# Clean the tree again so the daemon settles back to success before the death
# and restart assertions below.
failed_cycle="$(state_cycle)"
rm "$work/project/content/a.md" "$work/project/content/b.md"
recovered_cycle=""
for _ in $(seq 1 100); do
  recovered_cycle="$(state_cycle)"
  [[ "$recovered_cycle" != "$failed_cycle" ]] && break
  sleep 0.1
done
[[ "$recovered_cycle" != "$failed_cycle" ]] || { echo "daemon did not recover after removing the duplicate pair" >&2; exit 1; }
run_command "$work/validate-recovered-656.json" '{"mode":"validate"}'
node -e 'const r = require(process.argv[1]); if (r.exit_code !== 0 || r.failure_class !== "success") throw Error("tree not clean after A18 cleanup");' "$work/validate-recovered-656.json"

# Unexpected daemon death: the next demand reports the process failure, and a
# later demand (after the bounded backoff) restarts exactly one daemon.
kill -9 "$(daemon_pids | head -1)" 2>/dev/null || true
run_command "$work/validate-dead.json" '{"mode":"validate"}'
node -e '
  const r = require(process.argv[1]);
  if (r.failure_class !== "terminated" && r.failure_class !== "io") throw Error("dead daemon not reported as a process failure: " + r.failure_class);
' "$work/validate-dead.json"
restarted=""
for _ in $(seq 1 60); do
  run_command "$work/validate-restart.json" '{"mode":"validate"}' || true
  if node -e 'const r = require(process.argv[1]); process.exit(r.failure_class === "success" ? 0 : 1)' "$work/validate-restart.json"; then
    restarted=1
    break
  fi
  sleep 0.5
done
[[ -n "$restarted" ]] || { echo "daemon did not recover after an unexpected death" >&2; exit 1; }
[[ "$(daemon_count)" == "1" ]] || { echo "expected exactly one daemon after restart, found $(daemon_count)" >&2; exit 1; }

# Graceful shutdown: SIGTERM to the editor must reap the daemon (no orphan).
kill "$editor_pid" 2>/dev/null || true
wait "$editor_pid" 2>/dev/null
editor_exit=$?
editor_pid=""
[[ "$editor_exit" == "0" ]] || { echo "editor SIGTERM exit $editor_exit (expected 0)" >&2; exit 1; }
for _ in $(seq 1 50); do
  [[ "$(daemon_count)" == "0" ]] && break
  sleep 0.1
done
[[ "$(daemon_count)" == "0" ]] || { echo "orphaned validation daemon survived editor shutdown" >&2; exit 1; }

echo "editor validation daemon integration: ok"
