#!/usr/bin/env bash
# Black-box lifecycle guard for `boris watch --serve` (#392): the watch
# coordinator must serve the built tree over loopback, rebuild on content
# change, push an SSE reload event to connected clients, and shut down
# cleanly on SIGTERM (the server's accept thread must unblock and the process
# must exit 0 — the Linux accept-wake fix from #482 lives exactly here).
#
# Run from the repository root, or through:
#
#   zig build test-watch-serve-lifecycle
#
# All generated trees live under the ignored .zig-cache tree.
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "missing curl" >&2; exit 1; }

OUT=".zig-cache/watch-serve-lifecycle"
[[ "$OUT" == ".zig-cache/watch-serve-lifecycle" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/content" "$OUT/theme/layouts"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# Minimal site: one page, one layout with the standard content slot.
cat > "$OUT/content/index.md" <<'MD'
# Watch lifecycle

Version one.
MD

cat > "$OUT/theme/layouts/main.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>{{title}}</title></head>
<body data-layout="main">{{content}}</body>
</html>
HTML

WATCH_LOG="$OUT/watch.log"
SSE_LOG="$OUT/sse.log"
WATCH_PID=""
cleanup() {
    if [[ -n "$WATCH_PID" ]]; then
        kill -TERM "$WATCH_PID" 2>/dev/null || true
        wait "$WATCH_PID" 2>/dev/null || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

note "start boris watch --serve (ephemeral port)"
"$BORIS" watch \
    --input "$OUT/content" \
    --theme "$OUT/theme" \
    --html-dir "$OUT/site" \
    --serve --port 0 \
    >"$WATCH_LOG" 2>&1 &
WATCH_PID=$!

# The preview URL is printed once the loopback server is bound; poll for it.
PORT=""
for _ in $(seq 1 40); do
    PORT="$(sed -n 's/.*preview: http:\/\/127\.0\.0\.1:\([0-9]*\)\/.*/\1/p' "$WATCH_LOG" | head -1)"
    [[ -n "$PORT" ]] && break
    kill -0 "$WATCH_PID" 2>/dev/null || fail "watch process exited before binding the preview server; log: $(tail -3 "$WATCH_LOG")"
    sleep 0.25
done
[[ -n "$PORT" ]] || fail "preview server never bound (no URL in log)"
pass "preview server bound on 127.0.0.1:$PORT"

note "initial tree is served"
BODY="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/")"
echo "$BODY" | grep -q "Version one." || fail "served page missing initial content"
pass "served page contains initial content"

note "SSE stream delivers the initial reload event"
curl -s -N --max-time 8 "http://127.0.0.1:$PORT/__boris/events" >"$SSE_LOG" &
SSE_PID=$!
sleep 1
grep -q "event: reload" "$SSE_LOG" || fail "no initial SSE reload event"
pass "initial SSE reload event received"

note "content edit triggers a rebuild and a second reload event"
cat > "$OUT/content/index.md" <<'MD'
# Watch lifecycle

Version two.
MD

# Rebuild lands within poll (500ms) + debounce (100ms); allow slack.
UPDATED=""
for _ in $(seq 1 40); do
    UPDATED="$(curl -s --max-time 5 "http://127.0.0.1:$PORT/" | grep -c "Version two." || true)"
    [[ "$UPDATED" == "1" ]] && break
    sleep 0.25
done
[[ "$UPDATED" == "1" ]] || fail "served page never reflected the content edit"
pass "served page updated after edit"

# The SSE connection from before the edit must now carry a second reload
# event (generation bumped). Allow the debounced rebuild to finish first.
for _ in $(seq 1 40); do
    EVENTS="$(grep -c "event: reload" "$SSE_LOG" || true)"
    [[ "$EVENTS" -ge 2 ]] && break
    sleep 0.25
done
[[ "$EVENTS" -ge 2 ]] || fail "SSE stream never delivered the post-rebuild reload event (got $EVENTS)"
pass "SSE reload event delivered after rebuild"

kill "$SSE_PID" 2>/dev/null || true
wait "$SSE_PID" 2>/dev/null || true

note "SIGTERM shuts the watcher down cleanly (exit 0)"
kill -TERM "$WATCH_PID"
RC=0
wait "$WATCH_PID" || RC=$?
WATCH_PID=""
[[ "$RC" == "0" ]] || fail "watch process exited $RC on SIGTERM (expected 0)"
grep -q "watch: received shutdown signal" "$WATCH_LOG" || fail "no shutdown message in watch log"
pass "clean SIGTERM shutdown (exit 0, signal message logged)"

rm -rf "$OUT"
echo "watch-serve-lifecycle: all assertions passed"
