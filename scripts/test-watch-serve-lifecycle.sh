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

note "profile-driven watch selects its layout and static directory"
mkdir -p "$OUT/static"
printf 'Profile robots one.\n' >"$OUT/static/robots.txt"
cat >"$OUT/content/index.md" <<'MD'
---
id: index
title: Profile watch
status: published
published_at: 2024-01-20T14:30:00Z
summary: Watch profile metadata.
---

# Watch lifecycle

Version two.
MD
printf '<html><head>{{head}}</head><body>PROFILE-LAYOUT {{content}}</body></html>\n' >"$OUT/theme/layouts/home.html"
cat > "$OUT/boris.json" <<'JSON'
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "publication": {
    "target": "github-pages", "base_url": "https://example.test/",
    "origin": "https://example.test", "base_path": ""
  },
  "targets": [{
    "name": "public", "output": "profile-site", "public": true, "theme": "theme",
    "layout_rules": [{"selector": "id:index", "layout": "theme/layouts/home.html"}],
    "static": {"dir": "static"}
  }],
  "nostr": {
    "enabled": true,
    "pubkey": "a695f6b60119d9521934a691347d9f78e8770b56da16bb255ee286ddf9fda919",
    "articles": ["index"], "relays": ["wss://relay.example.com"]
  }
}
JSON
WATCH_LOG="$OUT/profile-watch.log"
"$BORIS" watch --profile "$OUT/boris.json" --serve --port 0 >"$WATCH_LOG" 2>&1 &
WATCH_PID=$!
PORT=""
for _ in $(seq 1 40); do
    PORT="$(sed -n 's/.*preview: http:\/\/127\.0\.0\.1:\([0-9]*\)\/.*/\1/p' "$WATCH_LOG" | head -1)"
    [[ -n "$PORT" ]] && break
    kill -0 "$WATCH_PID" 2>/dev/null || fail "profile watch exited: $(tail -3 "$WATCH_LOG")"
    sleep 0.25
done
[[ -n "$PORT" ]] || fail "profile preview server never bound"
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" | grep -q PROFILE-LAYOUT || fail "profile layout was ignored"
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/robots.txt" | grep -q 'robots one' || fail "profile static directory was ignored"
grep -q 'nostr:naddr1' "$OUT/profile-site/index.html" || fail "profile Nostr links were ignored"
pass "profile target is served with its rule layout and static files"

note "profile watch rebuilds layout and static changes"
printf '<html><head>{{head}}</head><body>PROFILE-UPDATED {{content}}</body></html>\n' >"$OUT/theme/layouts/home.html"
printf 'Profile robots two.\n' >"$OUT/static/robots.txt"
UPDATED=""
for _ in $(seq 1 40); do
    if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" | grep -q PROFILE-UPDATED \
        && curl -fsS --max-time 5 "http://127.0.0.1:$PORT/robots.txt" | grep -q 'robots two'; then
        UPDATED="yes"
        break
    fi
    sleep 0.25
done
[[ "$UPDATED" == yes ]] || fail "profile layout/static edits did not rebuild"
grep -q 'nostr:naddr1' "$OUT/profile-site/index.html" || fail "Nostr links disappeared on rebuild"
pass "workspace-relative layout and static changes rebuilt"

note "profile watch preserves last-good output and recovers from content errors"
printf '%s\n' '---' 'parent: missing-parent' '---' 'Broken page.' >"$OUT/content/index.md"
for _ in $(seq 1 40); do
    grep -q EPARENTMISSING "$WATCH_LOG" && break
    sleep 0.25
done
grep -q EPARENTMISSING "$WATCH_LOG" || fail "profile watch never reported the content failure"
kill -0 "$WATCH_PID" 2>/dev/null || fail "profile watcher stopped on recoverable error"
curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" | grep -q PROFILE-UPDATED || fail "last-good output was lost"
printf '# Watch lifecycle\n\nProfile recovered.\n' >"$OUT/content/index.md"
UPDATED=""
for _ in $(seq 1 40); do
    if curl -fsS --max-time 5 "http://127.0.0.1:$PORT/" | grep -q 'Profile recovered'; then
        UPDATED="yes"
        break
    fi
    sleep 0.25
done
[[ "$UPDATED" == yes ]] || fail "profile watcher never recovered"
kill -TERM "$WATCH_PID"
RC=0
wait "$WATCH_PID" || RC=$?
WATCH_PID=""
[[ "$RC" == 0 ]] || fail "profile watcher exited $RC on SIGTERM"
pass "profile watcher recovered and shut down cleanly"

rm -rf "$OUT"
echo "watch-serve-lifecycle: all assertions passed"
