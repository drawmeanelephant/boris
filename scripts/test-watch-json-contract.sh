#!/usr/bin/env bash
# Black-box contract guard for `boris watch --watch-json` (#644): the
# machine-readable stderr stream must be exactly NDJSON — one JSON object per
# line with a pinned key order — never interleaved with prose progress or
# prose diagnostics, and the event sequence must be deterministic.
#
# Run from the repository root, or through:
#
#   zig build test-watch-json-contract
#
# All generated trees live under the ignored .zig-cache tree. Paths are kept
# relative (mirroring scripts/test-watch-serve-lifecycle.sh) because layout
# paths reject absolute spellings.
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/watch-json-contract"
[[ "$OUT" == ".zig-cache/watch-json-contract" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/content" "$OUT/theme/layouts"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# Minimal site: one page, one layout with the standard content slot.
cat > "$OUT/content/index.md" <<'MD'
# Watch JSON contract

Version one.
MD

cat > "$OUT/theme/layouts/main.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>{{title}}</title></head>
<body data-layout="main">{{content}}</body>
</html>
HTML

ERR="$OUT/stderr.log"
STDOUT="$OUT/stdout.log"
WATCH_PID=""
cleanup() {
    if [[ -n "$WATCH_PID" ]]; then
        kill -TERM "$WATCH_PID" 2>/dev/null || true
        wait "$WATCH_PID" 2>/dev/null || true
    fi
    rm -rf "$OUT"
}
trap cleanup EXIT

# Poll stderr until a line matches $1 (an extended regex). Fails if the
# watcher exits first, so a silent crash cannot be mistaken for a timeout.
wait_for() {
    local i
    for i in $(seq 1 80); do
        grep -Eq "$1" "$ERR" 2>/dev/null && return 0
        kill -0 "$WATCH_PID" 2>/dev/null || fail "watch exited before observing: $1 (stderr tail: $(tail -3 "$ERR" 2>/dev/null))"
        sleep 0.25
    done
    fail "timed out waiting for: $1 (stderr tail: $(tail -5 "$ERR" 2>/dev/null))"
}

# $1 is an exact whole line that must appear in the stream (byte shape).
expect_line() {
    grep -Fx "$1" "$ERR" >/dev/null 2>&1 || fail "missing exact NDJSON line: $1"
}

# $1 is an extended regex that must match a whole line (key order pinned,
# timing/count values allowed to vary).
expect_shape() {
    grep -E "$1" "$ERR" >/dev/null 2>&1 || fail "missing NDJSON shape: $1"
}

# The hello handshake pins the compiler id exactly, so derive it from the
# binary instead of hardcoding a version that will bump.
COMPILER_ID="$("$BORIS" --version)"
[[ -n "$COMPILER_ID" ]] || fail "could not read compiler id from --version"

note "start boris watch --watch-json"
"$BORIS" watch --watch-json \
    --input "$OUT/content" \
    --theme "$OUT/theme" \
    --html-dir "$OUT/site" \
    >"$STDOUT" 2>"$ERR" &
WATCH_PID=$!

wait_for '"event":"hello"'
wait_for '"event":"watcher-started"'

note "hello is the first record and pins the schema + compiler id"
FIRST_LINE="$(head -1 "$ERR")"
[[ "$FIRST_LINE" == "{\"event\":\"hello\",\"watch_events_schema\":1,\"compiler\":\"$COMPILER_ID\"}" ]] \
    || fail "hello line is not the versioned handshake: $FIRST_LINE"
pass "hello handshake byte shape"

note "initial build events are byte-exact"
expect_line '{"event":"build-started","phase":"initial","mode":"html","targets":["default"]}'
expect_shape '^\{"event":"build-succeeded","phase":"initial","mode":"html","targets":\["default"\],"pages_written":[0-9]+,"duration_ms":[0-9]+\}$'
expect_line '{"event":"watcher-started","mode":"html","targets":["default"]}'
pass "initial sequence byte shapes"

note "stderr is exclusively NDJSON (no prose leakage)"
if grep -vE '^\{"event":"' "$ERR" | grep -q .; then
    fail "prose leaked into the NDJSON stream: $(grep -vE '^\{"event":"' "$ERR" | head -1)"
fi
pass "no prose on stderr"

note "content edit emits rebuild events naming the changed path"
# Write atomically: `.tmp` is ignored by the watcher, so the rename is a
# single modify event rather than a truncate+rewrite burst.
cat > "$OUT/content/index.md.tmp" <<'MD'
# Watch JSON contract

Version two.
MD
mv "$OUT/content/index.md.tmp" "$OUT/content/index.md"
wait_for '"event":"build-succeeded","phase":"rebuild"'
expect_line '{"event":"build-started","phase":"rebuild","mode":"html","targets":["default"],"changed":["index.md"]}'
expect_shape '^\{"event":"build-succeeded","phase":"rebuild","mode":"html","targets":\["default"\],"changed":\["index.md"\],"pages_written":[0-9]+,"duration_ms":[0-9]+\}$'
pass "rebuild sequence + changed-path byte shapes"

note "a recoverable content failure emits build-failed with structured diagnostics"
cat > "$OUT/content/index.md.tmp" <<'MD'
# Watch JSON contract

See [[does-not-exist]].
MD
mv "$OUT/content/index.md.tmp" "$OUT/content/index.md"
wait_for '"event":"build-failed"'
# Outer key order pinned; the diagnostics array carries the report shape.
expect_shape '^\{"event":"build-failed","phase":"rebuild","mode":"html","targets":\["default"\],"changed":\["index.md"\],"errors":[0-9]+,"diagnostics":\[.*\],"recoverable":true,"duration_ms":[0-9]+\}$'
grep -q '"severity":"error","code":"EREFERENCEMISSING","message":"' "$ERR" \
    || fail "build-failed diagnostics missing the report-shape EREFERENCEMISSING object"
pass "build-failed recoverable=true with structured diagnostics"

# The failed rebuild must not have terminated the watcher: the only way to
# reach this point is a live process.
kill -0 "$WATCH_PID" 2>/dev/null || fail "watcher exited after a recoverable content failure"

note "SIGTERM shuts down cleanly with watch-stopped (exit 0)"
kill -TERM "$WATCH_PID"
RC=0
wait "$WATCH_PID" || RC=$?
WATCH_PID=""
[[ "$RC" == "0" ]] || fail "watch exited $RC on SIGTERM (expected 0)"
expect_line '{"event":"watch-stopped","reason":"signal"}'
pass "clean SIGTERM shutdown with watch-stopped event"

note "events are on stderr only; stdout stays empty"
[[ ! -s "$STDOUT" ]] || fail "stdout is not empty: $(head -1 "$STDOUT")"
pass "stdout empty"

note "the event sequence is deterministic"
SEQ="$(grep -o '"event":"[a-z-]*"' "$ERR" | sed 's/"event"://; s/"//g' | tr '\n' ' ')"
EXPECTED="hello build-started build-succeeded watcher-started build-started build-succeeded build-started build-failed watch-stopped "
[[ "$SEQ" == "$EXPECTED" ]] || fail "unexpected event sequence: $SEQ"
pass "event sequence pinned"

echo "watch-json-contract: all assertions passed"
