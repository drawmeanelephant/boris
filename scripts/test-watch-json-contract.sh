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

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
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

# Poll stderr until a line matches an extended regex. Two call forms:
#   wait_for REGEX                  → REGEX against $ERR (phase-1 form)
#   wait_for FILE REGEX [PID]       → REGEX against FILE (multi-phase form)
# Fails if the watcher exits first, so a silent crash cannot be mistaken for
# a timeout.
wait_for() {
    local file="$ERR"
    local re=""
    local pid="$WATCH_PID"
    if [[ $# -ge 2 ]]; then
        file="$1"
        re="$2"
        [[ $# -ge 3 ]] && pid="$3"
    else
        re="$1"
    fi
    local i
    for i in $(seq 1 80); do
        grep -Eq "$re" "$file" 2>/dev/null && return 0
        kill -0 "$pid" 2>/dev/null || fail "watch exited before observing: $re (stderr tail: $(tail -3 "$file" 2>/dev/null))"
        sleep 0.25
    done
    fail "timed out waiting for: $re (stderr tail: $(tail -5 "$file" 2>/dev/null))"
}

# $1 is an exact whole line that must appear in the stream (byte shape);
# $2 is the file to search (default $ERR).
expect_line() {
    local line="$1"
    local file="${2:-$ERR}"
    grep -Fx "$line" "$file" >/dev/null 2>&1 || fail "missing exact NDJSON line: $line"
}

# $1 is an extended regex that must match a whole line (key order pinned,
# timing/count values allowed to vary); $2 is the file to search (default $ERR).
expect_shape() {
    local re="$1"
    local file="${2:-$ERR}"
    grep -E "$re" "$file" >/dev/null 2>&1 || fail "missing NDJSON shape: $re"
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

# ---------------------------------------------------------------------------
# Phase 2: `validate --watch --watch-json` — the zero-write validation daemon
# (#647). Same NDJSON protocol with mode "validate"; nothing is written.
# ---------------------------------------------------------------------------
note "phase 2: start boris validate --watch --watch-json"
# The html phase left a broken wiki-link in index.md; restore valid content.
cat > "$OUT/content/index.md" <<'MD'
# Watch JSON contract

Version three.
MD
VERR="$OUT/validate-stderr.log"
VOUT="$OUT/validate-stdout.log"
"$BORIS" validate --watch --watch-json \
    --input "$OUT/content" \
    --theme "$OUT/theme" \
    >"$VOUT" 2>"$VERR" &
VPID=$!

wait_for "$VERR" '"event":"hello"' "$VPID"
wait_for "$VERR" '"event":"watcher-started"' "$VPID"

note "validate events: initial sequence byte shapes"
expect_line '{"event":"build-started","phase":"initial","mode":"validate","targets":["default"]}' "$VERR"
expect_shape '^\{"event":"build-succeeded","phase":"initial","mode":"validate","targets":\["default"\],"pages_written":null,"duration_ms":[0-9]+\}$' "$VERR"
expect_line '{"event":"watcher-started","mode":"validate","targets":["default"]}' "$VERR"
pass "validate initial sequence byte shapes"

note "validate rebuild names the changed path and reports no pages written"
cat > "$OUT/content/index.md.tmp" <<'MD'
# Watch JSON contract

Version four.
MD
mv "$OUT/content/index.md.tmp" "$OUT/content/index.md"
wait_for "$VERR" '"event":"build-succeeded","phase":"rebuild"' "$VPID"
expect_line '{"event":"build-started","phase":"rebuild","mode":"validate","targets":["default"],"changed":["index.md"]}' "$VERR"
expect_shape '^\{"event":"build-succeeded","phase":"rebuild","mode":"validate","targets":\["default"\],"changed":\["index.md"\],"pages_written":null,"duration_ms":[0-9]+\}$' "$VERR"
pass "validate rebuild sequence + changed-path byte shapes"

note "a recoverable content failure emits build-failed mode validate"
cat > "$OUT/content/index.md.tmp" <<'MD'
# Watch JSON contract

See [[does-not-exist]].
MD
mv "$OUT/content/index.md.tmp" "$OUT/content/index.md"
wait_for "$VERR" '"event":"build-failed"' "$VPID"
expect_shape '^\{"event":"build-failed","phase":"rebuild","mode":"validate","targets":\["default"\],"changed":\["index.md"\],"errors":[0-9]+,"diagnostics":\[.*\],"recoverable":true,"duration_ms":[0-9]+\}$' "$VERR"
grep -q '"severity":"error","code":"EREFERENCEMISSING"' "$VERR" \
    || fail "validate build-failed diagnostics missing the report-shape EREFERENCEMISSING object"
pass "validate build-failed recoverable=true with structured diagnostics"

note "the validate daemon writes no output tree (zero-write)"
[[ ! -e "$OUT/validate-site" ]] || fail "validate --watch created an output tree"
pass "zero-write daemon leaves no output tree"

note "SIGTERM stops the validate daemon with watch-stopped (exit 0)"
kill -TERM "$VPID"
RC=0
wait "$VPID" || RC=$?
VPID=""
[[ "$RC" == "0" ]] || fail "validate watch exited $RC on SIGTERM (expected 0)"
expect_line '{"event":"watch-stopped","reason":"signal"}' "$VERR"
pass "validate clean SIGTERM shutdown"

note "validate stream is exclusively NDJSON; stdout empty"
if grep -vE '^\{"event":"' "$VERR" | grep -q .; then
    fail "prose leaked into the validate NDJSON stream: $(grep -vE '^\{"event":"' "$VERR" | head -1)"
fi
[[ ! -s "$VOUT" ]] || fail "validate stdout is not empty: $(head -1 "$VOUT")"
pass "validate stream purity"

# ---------------------------------------------------------------------------
# Phase 3: `validate --watch --report PATH` — the report file is rewritten
# (replaced, never appended) on every cycle (#647).
# ---------------------------------------------------------------------------
note "phase 3: validate --watch --report rewrites the report file every cycle"
cat > "$OUT/content/index.md" <<'MD'
# Watch JSON contract

Version five.
MD
RERR="$OUT/report-stderr.log"
ROUT="$OUT/report-stdout.log"
REPORT="$OUT/report.json"
"$BORIS" validate --watch --report "$REPORT" \
    --input "$OUT/content" \
    --theme "$OUT/theme" \
    >"$ROUT" 2>"$RERR" &
RPID=$!

for i in $(seq 1 80); do
    grep -q '"ok": true' "$REPORT" 2>/dev/null && break
    kill -0 "$RPID" 2>/dev/null || fail "report watch exited before the initial ok report"
    sleep 0.25
done
grep -q '"ok": true' "$REPORT" 2>/dev/null || fail "initial report is not ok:true"
pass "initial cycle writes ok:true report"

note "a failed cycle rewrites the report (not append) with diagnostics"
cat > "$OUT/content/index.md.tmp" <<'MD'
# Watch JSON contract

See [[does-not-exist]].
MD
mv "$OUT/content/index.md.tmp" "$OUT/content/index.md"
for i in $(seq 1 80); do
    grep -q '"ok": false' "$REPORT" 2>/dev/null && break
    kill -0 "$RPID" 2>/dev/null || fail "report watch exited before the failed report"
    sleep 0.25
done
grep -q '"ok": false' "$REPORT" 2>/dev/null || fail "report was not rewritten with ok:false"
grep -q 'EREFERENCEMISSING' "$REPORT" 2>/dev/null || fail "failed report lacks the EREFERENCEMISSING diagnostic"
pass "failed cycle rewrites report to ok:false with diagnostics"

note "a corrected cycle rewrites the report back to ok:true as one document"
cat > "$OUT/content/index.md.tmp" <<'MD'
# Watch JSON contract

Version six.
MD
mv "$OUT/content/index.md.tmp" "$OUT/content/index.md"
for i in $(seq 1 80); do
    grep -q '"ok": true' "$REPORT" 2>/dev/null && break
    kill -0 "$RPID" 2>/dev/null || fail "report watch exited before the corrected report"
    sleep 0.25
done
grep -q '"ok": true' "$REPORT" 2>/dev/null || fail "report was not rewritten back to ok:true"
JSON_DOCS="$(grep -c '^{' "$REPORT")"
[[ "$JSON_DOCS" == "1" ]] || fail "report file has $JSON_DOCS JSON documents (expected 1 replacement)"
pass "report rewritten per cycle as a single document"

note "SIGTERM stops the report daemon cleanly (exit 0)"
kill -TERM "$RPID"
RC=0
wait "$RPID" || RC=$?
RPID=""
[[ "$RC" == "0" ]] || fail "report watch exited $RC on SIGTERM (expected 0)"
pass "report daemon clean SIGTERM shutdown"

echo "watch-json-contract: all assertions passed"
