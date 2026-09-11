#!/usr/bin/env bash
# Table-driven conformance guard for docs/contracts/editor-host.md.
#
# The contract is the source of truth for this test: the endpoint table in §4,
# the error taxonomy in §9, and the fixed commands in §6/§7 are parsed out of
# the Markdown and reconciled against the host — in both directions. A route or
# error code that exists in code but not in the contract fails, and a documented
# row the host does not implement fails too. On top of that reconciliation the
# real host is booted and every documented endpoint is probed, every documented
# error code is driven to its documented status, and a generated set of
# near-miss and plausible-but-absent /api/* paths must all answer 404.
#
#   ./editor/scripts/test-host-contract.sh BORIS_BIN EDITOR_BIN UI_DIR
#
# Every code in §9 is driven live: the script fails if a documented code has no
# producing request, so there is no static-only list to rot. That needs fixtures
# and stub compilers — a 50 000-file project (`too_many_files`), a non-regular
# file where a page is expected (`io_error`), an incapable stub
# (`unsupported_boris_artifact`, `watch_unsupported`), a stub whose build report
# carries an unsafe diagnostic source path (`unsafe_artifact_path`), a stub that
# emits an unsupported `watch_events_schema` (`watch_schema_unsupported`), a
# non-executable `--boris` path (`boris_unavailable`), and `/bin/echo` as
# `--version` garbage (`invalid_boris_version`). Two further stubs flood the
# watch event ring past its documented bounds (§7.3): one over the 100-event
# count cap (pinning `gap`, `oldest_seq`, `dropped_lines`, and the rule that an
# unparseable line consumes no `seq`), one over the ~4 MiB byte budget (where
# eviction is driven by bytes, not count).
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BORIS_BIN EDITOR_BIN UI_DIR" >&2
  exit 2
fi

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
contract="$root/docs/contracts/editor-host.md"
server_src="$root/editor/src/server.zig"
watch_src="$root/editor/src/watch_daemon.zig"

for f in "$contract" "$server_src" "$watch_src"; do
  [[ -f "$f" ]] || { echo "missing required file: $f" >&2; exit 2; }
done

boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
editor_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ui_dir="$(cd "$3" && pwd)"

work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-contract.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

failures=0
note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; failures=$((failures + 1)); }
skip() { printf '    SKIP %s\n' "$*"; }

# --- contract and implementation tables ------------------------------------

# Endpoint table rows in §4: "| `/api/x` | METHOD | … |" -> "path|methods".
documented_routes() {
  awk '/^## 4\. Endpoint surface/,/^### 4\.1/' "$contract" |
    sed -n 's#^| `\(/api/[a-z0-9/-]*\)` | \([A-Z, ]*\) |.*$#\1|\2#p' |
    sort
}

# Routed /api/ paths the host actually dispatches (server.zig route()).
implemented_routes() {
  sed -n 's#.*std\.mem\.eql(u8, target, "\(/api/[a-z0-9/-]*\)").*#\1#p' "$server_src" |
    sort -u
}

# Error-code table rows in §9: "| `code` | 400 | … |" -> "code".
documented_codes() {
  awk '/^## 9\. Error taxonomy/,/^## 10\./' "$contract" |
    sed -n 's#^| `\([a-z0-9_]*\)` | [0-9]* |.*$#\1#p' |
    sort -u
}

# Every code the host can emit: the respondApiError taxonomy, the refusal
# literals built in buffers, and the watch daemon's startRefusal() reasons.
implemented_codes() {
  {
    sed -n 's#.*\.code = "\([a-z0-9_]*\)".*#\1#p' "$server_src"
    grep -ho 'error\\":\\"[a-z0-9_]*' "$root"/editor/src/*.zig | sed 's/error\\":\\"//'
    sed -n 's#.*return "\(watch_[a-z0-9_]*\)".*#\1#p' "$watch_src"
  } | sort -u
}

reconcile() { # label documented_stdin implemented_stdin
  local label="$1" documented="$2" implemented="$3" path
  local missing extra found
  missing="$(comm -23 <(printf '%s\n' "$documented" | grep -v '^$') <(printf '%s\n' "$implemented" | grep -v '^$') || true)"
  extra="$(comm -13 <(printf '%s\n' "$documented" | grep -v '^$') <(printf '%s\n' "$implemented" | grep -v '^$') || true)"
  if [[ -n "$missing" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && fail "$label documented but not implemented: $path"
    done <<<"$missing"
  fi
  if [[ -n "$extra" ]]; then
    while IFS= read -r path; do
      [[ -n "$path" ]] && fail "$label implemented but undocumented: $path"
    done <<<"$extra"
  fi
  if [[ -z "$missing" && -z "$extra" ]]; then
    found="$(printf '%s\n' "$documented" | grep -c . || true)"
    pass "$label: $found documented, $found implemented"
  fi
  return 0
}

note "reconciling docs/contracts/editor-host.md against the host"
DOCUMENTED_ROUTES="$(documented_routes)"
DOCUMENTED_CODES="$(documented_codes)"
reconcile "endpoint table (§4)" "$(printf '%s\n' "$DOCUMENTED_ROUTES" | sed 's/|.*//' | sort -u)" "$(implemented_routes)"
reconcile "error taxonomy (§9)" "$DOCUMENTED_CODES" "$(implemented_codes)"

# --- host boot helpers ------------------------------------------------------

start_host() { # boris_path log_name project_dir
  local boris="$1" log="$2" project="$3"
  : >"$work/$log"
  "$editor_bin" "$project" --boris "$boris" --ui-dir "$ui_dir" --port 0 >"$work/$log" 2>&1 &
  editor_pid=$!
  local _
  for _ in $(seq 1 100); do
    grep -q 'BORIS_EDITOR_URL=' "$work/$log" && break
    kill -0 "$editor_pid" 2>/dev/null || {
      echo "editor host failed to start:" >&2
      sed -n '1,60p' "$work/$log" >&2
      exit 1
    }
    sleep 0.05
  done
  local launch
  launch="$(awk '/^BORIS_EDITOR_URL=/{print substr($0, length("BORIS_EDITOR_URL=") + 1); exit}' "$work/$log")"
  if ! printf '%s' "$launch" | grep -Eq '^http://127\.0\.0\.1:[0-9]+/#token=[0-9a-f]{32}$'; then
    echo "launch line contract violated: BORIS_EDITOR_URL=$launch" >&2
    exit 1
  fi
  base_url="${launch%%/#*}"
  token="${launch##*#token=}"
  port="$(printf '%s' "$base_url" | sed -E 's#.*:([0-9]+)$#\1#')"
}

stop_host() {
  if [[ -n "$editor_pid" ]]; then
    kill "$editor_pid" 2>/dev/null || true
    wait "$editor_pid" 2>/dev/null || true
    editor_pid=""
  fi
}

status_of() { printf '%s' "$1" | tail -1; }
body_of() { printf '%s' "$1" | sed '$d'; }

request() { # method path [body] [content_type]
  local method="$1" path="$2" body="${3-}" ctype="${4-}"
  local args=(-s -X "$method" -H "Host: 127.0.0.1:$port"
    -H "X-Boris-Editor-Token: $token" -w $'\n%{http_code}')
  [[ -n "$ctype" ]] && args+=(-H "Content-Type: $ctype")
  [[ -n "$body" ]] && args+=(--data-binary "$body")
  curl "${args[@]}" "$base_url$path"
}

allow_of() { # method path
  curl -s -o /dev/null -D - -X "$1" \
    -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" \
    "$base_url$2" | tr -d '\r' | sed -n 's/^[Aa]llow: //p'
}

fingerprint_of() { sed -n 's/.*"fingerprint":"\([0-9a-f]\{64\}\)".*/\1/p' | awk 'NR==1'; }

# Field readers for the single-line state/event bodies: `-oE` lists every match
# in order, and the first is the top-level field (nested objects such as
# `last_event` follow it).
number_of() { printf '%s' "$2" | grep -oE "\"$1\":[0-9]+" | sed -n '1p' | sed 's/^[^:]*://'; }
bool_of() { printf '%s' "$2" | grep -oE "\"$1\":(true|false)" | sed -n '1p' | sed 's/^[^:]*://'; }

project="$work/project"
"$boris_bin" init "$project" >/dev/null 2>&1
mkdir -p "$project/.boris"

start_host "$boris_bin" host.log "$project"

# --- §4: every documented endpoint exists with exactly its methods ---------

note "probing the documented endpoint table against the live host"
route_count=0
while IFS='|' read -r path methods; do
  [[ -n "$path" ]] || continue
  [[ -n "$methods" ]] || continue
  route_count=$((route_count + 1))
  if [[ "$methods" == *POST* ]]; then
    allow="$(allow_of GET "$path")"
    if [[ "$allow" != "POST" ]]; then
      fail "$path: GET should be 405 with 'Allow: POST' (got '${allow:-<none>}')"
      continue
    fi
    pass "$path: POST-only route confirmed"
  else
    allow="$(allow_of PUT "$path")"
    if [[ "$allow" != "GET, HEAD" ]]; then
      fail "$path: PUT should be 405 with 'Allow: GET, HEAD' (got '${allow:-<none>}')"
      continue
    fi
    response="$(request GET "$path")"
    if [[ "$(status_of "$response")" != "200" ]]; then
      fail "$path: documented GET answered $(status_of "$response"), expected 200"
      continue
    fi
    pass "$path: GET 200, methods pinned to GET, HEAD"
  fi
done <<<"$DOCUMENTED_ROUTES"

# --- §4: routes that are not in the contract must not be reachable ----------

# Near-misses are generated from the documented table, so a new endpoint grows
# this set automatically. The explicit list is the plausible-but-absent set: a
# convenience route someone might add without a contract change.
undocumented_probes() {
  local path
  while IFS='|' read -r path _; do
    [[ -n "$path" ]] || continue
    printf '%s\n' "$path/" "$path/extra" "${path%/*}"
  done <<<"$DOCUMENTED_ROUTES"
  cat <<'ABSENT'
/api/file
/api/files/move
/api/files/copy
/api/files/mkdir
/api/files/download
/api/files/upload
/api/files/stat
/api/commands
/api/commands/list
/api/routes
/api/schema
/api/contract
/api/metrics
/api/logs
/api/shutdown
/api/quit
/api/serve
/api/preview/serve
/api/preview/url
/api/preview/port
/api/standard-site
/api/nostr
/api/publish
/api/deploy
/api/git
/api/fs
/api/settings
/api/token
/api/auth
/api/Health
/api/HEALTH
/api/healthz
/api/version/latest
/api/debug
/api/internal/health
/api/_routes
/api
/api/
/api//health
/api/./health
ABSENT
}

note "rejecting undocumented /api/* paths"
documented_path_list="$(printf '%s\n' "$DOCUMENTED_ROUTES" | sed 's/|.*//' | sort -u)"
undocumented_count=0
undocumented_bad=0
while IFS= read -r path; do
  [[ -n "$path" ]] || continue
  # A generated parent may itself be a documented route; this guard keeps the
  # probe set honest as the contract grows.
  if printf '%s\n' "$documented_path_list" | grep -qxF "$path"; then continue; fi
  undocumented_count=$((undocumented_count + 1))
  # --path-as-is keeps curl from normalizing "//" and "./" away: the host must
  # reject the path it actually received, not a tidied one.
  code="$(curl -s --path-as-is -o /dev/null -w '%{http_code}' \
    -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" \
    "$base_url$path")"
  if [[ "$code" != "404" ]]; then
    undocumented_bad=$((undocumented_bad + 1))
    fail "$path: undocumented route answered $code, expected 404"
  fi
done < <(undocumented_probes | sort -u)
[[ "$undocumented_bad" -eq 0 ]] && pass "$undocumented_count undocumented paths all rejected with 404"

# A query string is stripped before routing, so an unknown parameter is ignored.
response="$(request GET '/api/health?ignored=1')"
if [[ "$(status_of "$response")" == "200" ]]; then
  pass "unknown query parameter is stripped, not rejected"
else
  fail "unknown query parameter changed the route: $(status_of "$response")"
fi

# --- transport discipline ---------------------------------------------------

note "transport discipline"
for probe in "bad host" "bad token" "bad origin" "no token"; do
  case "$probe" in
    "bad host")
      code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: attacker.test:$port" \
        -H "X-Boris-Editor-Token: $token" "$base_url/api/health")"
      ;;
    "bad token")
      code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1:$port" \
        -H "X-Boris-Editor-Token: 00000000000000000000000000000000" "$base_url/api/health")"
      ;;
    "bad origin")
      code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1:$port" \
        -H "X-Boris-Editor-Token: $token" -H "Origin: https://attacker.test" "$base_url/api/health")"
      ;;
    "no token")
      code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: 127.0.0.1:$port" "$base_url/api/health")"
      ;;
  esac
  if [[ "$code" == "403" ]]; then
    pass "$probe -> 403"
  else
    fail "$probe -> $code, expected 403"
  fi
done

# --- §9: error taxonomy, the codes a healthy project can produce ------------

note "driving documented error codes to their documented status"
probed_codes=""
while IFS='|' read -r code method path body ctype status; do
  [[ -n "$code" ]] || continue
  response="$(request "$method" "$path" "$body" "$ctype")"
  got_status="$(status_of "$response")"
  got_body="$(body_of "$response")"
  probed_codes="$probed_codes$code"$'\n'
  if [[ "$got_status" != "$status" ]]; then
    fail "$code: expected $status, got $got_status ($method $path)"
    continue
  fi
  if ! printf '%s' "$got_body" | grep -q "\"error\":\"$code\""; then
    fail "$code: body did not carry the code: $got_body"
    continue
  fi
  pass "$code -> $status"
done <<'TABLE'
invalid_json|POST|/api/files/open|not json|application/json|400
invalid_query|GET|/api/watch/events?after=abc|||400
invalid_path|POST|/api/files/open|{"path":"../secret"}|application/json|400
invalid_fingerprint|POST|/api/files/probe|{"path":"content/index.md","fingerprint":"zz"}|application/json|400
invalid_command_request|POST|/api/commands/run|{"mode":"impact"}|application/json|400
path_not_author_owned|POST|/api/files/open|{"path":"dist/index.html"}|application/json|403
file_not_found|POST|/api/files/open|{"path":"content/missing.md"}|application/json|404
path_already_exists|POST|/api/files/create|{"path":"content/index.md"}|application/json|409
unsupported_media_type|POST|/api/files/open|x|text/plain|415
TABLE

# invalid_utf8: a page with non-UTF-8 bytes on disk.
printf '\377\376\377' >"$project/content/binary.md"
response="$(request POST /api/files/open '{"path":"content/binary.md"}' application/json)"
if [[ "$(status_of "$response")" == "422" ]] && body_of "$response" | grep -q '"error":"invalid_utf8"'; then
  probed_codes="$probed_codes"$'invalid_utf8\n'
  pass "invalid_utf8 -> 422"
else
  fail "invalid_utf8: got $(status_of "$response") $(body_of "$response")"
fi
rm -f "$project/content/binary.md"

# payload_too_large: content one byte past the documented 8 MiB file cap, sized
# so the JSON body stays under the 9 MiB request ceiling and the content cap is
# the rule that fires.
big="$work/big.json"
{
  printf '{"path":"content/big.md","content":"'
  head -c 8388609 /dev/zero | tr '\0' 'a'
  printf '"}'
} >"$big"
response="$(curl -s -X POST -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" \
  -H 'Content-Type: application/json' --data-binary "@$big" -w $'\n%{http_code}' "$base_url/api/files/create")"
if [[ "$(status_of "$response")" == "413" ]] && body_of "$response" | grep -q '"error":"payload_too_large"'; then
  probed_codes="$probed_codes"$'payload_too_large\n'
  pass "payload_too_large -> 413"
else
  fail "payload_too_large: got $(status_of "$response")"
fi
[[ -e "$project/content/big.md" ]] && fail "payload_too_large wrote a file anyway"
rm -f "$big"

# io_error: a directory where a page is expected is not a regular file. §9 lists
# io_error as the residual failure branch, so this is its cheapest real producer.
mkdir "$project/content/dir.md"
response="$(request POST /api/files/open '{"path":"content/dir.md"}' application/json)"
if [[ "$(status_of "$response")" == "500" ]] && body_of "$response" | grep -q '"error":"io_error"'; then
  probed_codes="$probed_codes"$'io_error\n'
  pass "io_error -> 500 (non-regular file where a page is expected)"
else
  fail "io_error -> $(status_of "$response") $(body_of "$response")"
fi
rmdir "$project/content/dir.md"

# --- the documented file-operation outcomes ---------------------------------

note "documented file-operation outcomes"

# create (201) / rename (200) / delete refusal (409) / delete (200).
response="$(request POST /api/files/create '{"path":"content/extra.md","content":"x\n"}' application/json)"
[[ "$(status_of "$response")" == "201" ]] && pass "create -> 201" || fail "create -> $(status_of "$response")"
response="$(request POST /api/files/rename '{"path":"content/extra.md","new_path":"content/extra2.md"}' application/json)"
if [[ "$(status_of "$response")" == "200" ]] && body_of "$response" | grep -q '"status":"renamed"'; then
  pass "rename -> 200 renamed"
else
  fail "rename -> $(status_of "$response")"
fi
response="$(request POST /api/files/delete '{"path":"content/extra2.md","confirmed":false}' application/json)"
if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"confirmation_required"'; then
  probed_codes="$probed_codes"$'confirmation_required\n'
  pass "confirmation_required -> 409"
else
  fail "confirmation_required -> $(status_of "$response")"
fi
response="$(request POST /api/files/delete '{"path":"content/extra2.md","confirmed":true}' application/json)"
[[ "$(status_of "$response")" == "200" ]] && pass "delete -> 200" || fail "delete -> $(status_of "$response")"
[[ -e "$project/content/extra2.md" ]] && fail "confirmed delete left the file behind"

# probe unchanged (200) and read_only (409).
response="$(request POST /api/files/open '{"path":"content/index.md"}' application/json)"
fingerprint="$(body_of "$response" | fingerprint_of)"
[[ -n "$fingerprint" ]] && pass "open -> 200 with a 64-hex fingerprint" || fail "open did not return a fingerprint"
response="$(request POST /api/files/probe "{\"path\":\"content/index.md\",\"fingerprint\":\"$fingerprint\"}" application/json)"
if [[ "$(status_of "$response")" == "200" ]] && body_of "$response" | grep -q '"status":"unchanged"'; then
  pass "probe -> 200 unchanged"
else
  fail "probe -> $(status_of "$response") $(body_of "$response")"
fi
chmod 444 "$project/content/index.md"
response="$(request POST /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# x\\n\",\"fingerprint\":\"$fingerprint\"}" application/json)"
if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"read_only"'; then
  probed_codes="$probed_codes"$'read_only\n'
  pass "read_only -> 409"
else
  fail "read_only -> $(status_of "$response")"
fi
chmod 644 "$project/content/index.md"

# recovery snapshot (200) / list / clear (200).
response="$(request POST /api/recovery/snapshot "{\"path\":\"content/index.md\",\"content\":\"# unsaved\\n\",\"fingerprint\":\"$fingerprint\"}" application/json)"
[[ "$(status_of "$response")" == "200" ]] && pass "recovery snapshot -> 200" || fail "recovery snapshot -> $(status_of "$response")"
if request GET /api/recovery | grep -q '# unsaved'; then
  pass "recovery list returns the snapshot"
else
  fail "recovery list lost the snapshot"
fi
response="$(request POST /api/recovery/clear '{"path":"content/index.md"}' application/json)"
[[ "$(status_of "$response")" == "200" ]] && pass "recovery clear -> 200" || fail "recovery clear -> $(status_of "$response")"

# A symlinked artifact is refused, not followed. This is opportunistic: some
# hosts deny symlink creation, and coverage for unsafe_artifact_path comes from
# the stub compiler that reports an unsafe diagnostic source path.
if ln -s "$work/elsewhere.json" "$project/.boris/completion.json" 2>/dev/null; then
  response="$(request GET /api/authoring)"
  if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"unsafe_artifact_path"'; then
    pass "symlinked artifact refused with unsafe_artifact_path"
  else
    fail "symlinked artifact -> $(status_of "$response") $(body_of "$response")"
  fi
  rm -f "$project/.boris/completion.json"
else
  skip "symlinked artifact: this host denies symlink creation"
fi

# --- §7.4: the dist-writer seat ---------------------------------------------

note "managed watch daemon and the dist writer seat"
response="$(request POST /api/watch/start '{}' application/json)"
watch_start_status="$(status_of "$response")"
if [[ "$watch_start_status" == "200" ]]; then
  pass "watch start -> 200"
elif [[ "$watch_start_status" == "409" ]] && body_of "$response" | grep -q '"error":"watch_unsupported"'; then
  probed_codes="$probed_codes"$'watch_unsupported\n'
  pass "watch start -> 409 watch_unsupported (compiler without --watch-json)"
else
  fail "watch start -> $watch_start_status $(body_of "$response")"
fi
response="$(request GET /api/watch/state)"
[[ "$(status_of "$response")" == "200" ]] && pass "watch state -> 200" || fail "watch state -> $(status_of "$response")"
if [[ "$watch_start_status" == "200" ]]; then
  response="$(request POST /api/preview/rebuild '{}' application/json)"
  if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"watch_daemon_active"'; then
    probed_codes="$probed_codes"$'watch_daemon_active\n'
    pass "watch_daemon_active -> 409 while the daemon owns dist/"
  else
    fail "watch_daemon_active -> $(status_of "$response") $(body_of "$response")"
  fi
  response="$(request POST /api/watch/stop '{}' application/json)"
  [[ "$(status_of "$response")" == "200" ]] && pass "watch stop -> 200" || fail "watch stop -> $(status_of "$response")"
fi

# Rebuild is a documented endpoint; after the daemon is stopped it must work.
response="$(request POST /api/preview/rebuild '{}' application/json)"
if [[ "$(status_of "$response")" == "200" ]] && body_of "$response" | grep -q '"phase":"success"'; then
  pass "preview rebuild -> 200 success"
else
  fail "preview rebuild -> $(status_of "$response") $(body_of "$response")"
fi

stop_host

# --- degraded-host scenarios: the remaining codes ---------------------------

note "degraded-host scenarios"

# invalid_boris_version: a compiler that answers --version with garbage.
start_host /bin/echo echo.log "$project"
response="$(request GET /api/version)"
if [[ "$(status_of "$response")" == "502" ]] && body_of "$response" | grep -q '"error":"invalid_boris_version"'; then
  probed_codes="$probed_codes"$'invalid_boris_version\n'
  pass "invalid_boris_version -> 502"
else
  fail "invalid_boris_version -> $(status_of "$response") $(body_of "$response")"
fi
stop_host

# boris_unavailable: a --boris path that exists but cannot be executed.
printf 'not executable\n' >"$work/not-exec"
chmod 644 "$work/not-exec"
start_host "$work/not-exec" nonexec.log "$project"
response="$(request GET /api/version)"
if [[ "$(status_of "$response")" == "503" ]] && body_of "$response" | grep -q '"error":"boris_unavailable"'; then
  probed_codes="$probed_codes"$'boris_unavailable\n'
  pass "boris_unavailable -> 503"
else
  fail "boris_unavailable -> $(status_of "$response") $(body_of "$response")"
fi
stop_host

# A stub compiler: capability probes fail, and an unrecognized report version
# must be refused rather than adapted.
stub_project="$work/stub-project"
"$boris_bin" init "$stub_project" >/dev/null 2>&1
cat >"$work/stub-boris" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo "boris/9.9.9" ;;
  build) mkdir -p .boris; printf '{"schemaVersion":"9.9.9"}\n' > .boris/build-report.json ;;
esac
exit 0
STUB
chmod +x "$work/stub-boris"
start_host "$work/stub-boris" stub.log "$stub_project"
response="$(request GET /api/version)"
if [[ "$(status_of "$response")" == "200" ]] &&
  body_of "$response" | grep -q '"compiler_id":"boris/9.9.9"' &&
  body_of "$response" | grep -q '"validate_watch":false' &&
  body_of "$response" | grep -q '"watch_json":false'; then
  pass "stub compiler capability matrix is honest (validate_watch false, watch_json false)"
else
  fail "stub compiler version payload: $(body_of "$response")"
fi
response="$(request POST /api/commands/run '{"mode":"ir_build"}' application/json)"
if [[ "$(status_of "$response")" == "502" ]] && body_of "$response" | grep -q '"error":"unsupported_boris_artifact"'; then
  probed_codes="$probed_codes"$'unsupported_boris_artifact\n'
  pass "unsupported_boris_artifact -> 502"
else
  fail "unsupported_boris_artifact -> $(status_of "$response") $(body_of "$response")"
fi
response="$(request POST /api/watch/start '{}' application/json)"
if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"watch_unsupported"'; then
  probed_codes="$probed_codes"$'watch_unsupported\n'
  pass "watch_unsupported -> 409 on an incapable compiler"
else
  fail "watch_unsupported -> $(status_of "$response") $(body_of "$response")"
fi
stop_host

# A watch-capable stub: it advertises --watch-json, reports an unsafe diagnostic
# source path in its build report, and emits an unsupported `hello` schema.
stub_watch_project="$work/stub-watch-project"
"$boris_bin" init "$stub_watch_project" >/dev/null 2>&1
cat >"$work/stub-watch-boris" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo "boris/9.9.9" ;;
  watch)
    case "$2" in
      --help) echo "--watch-json" ;;
      *) printf '{"event":"hello","watch_events_schema":99,"compiler":"boris/9.9.9"}\n' >&2; exec sleep 5 ;;
    esac
    ;;
  build)
    mkdir -p .boris
    printf '{"schemaVersion":"0.2.0","compilerId":"boris/9.9.9","ok":false,"contentRoot":"content","outDir":".boris","pageCount":1,"errorCount":1,"diagnostics":[{"severity":"error","code":"EFRONTMATTER","message":"bad frontmatter","remediation":"fix it","sourcePath":"../../etc/passwd","line":1,"column":1,"id":null}]}\n' > .boris/build-report.json
    ;;
esac
exit 0
STUB
chmod +x "$work/stub-watch-boris"
start_host "$work/stub-watch-boris" stub-watch.log "$stub_watch_project"
response="$(request GET /api/version)"
if body_of "$response" | grep -q '"watch_json":true'; then
  pass "watch-capable stub advertises watch_json, so a start is not refused as unsupported"
else
  fail "watch-capable stub capability matrix: $(body_of "$response")"
fi
response="$(request POST /api/commands/run '{"mode":"ir_build"}' application/json)"
if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"unsafe_artifact_path"'; then
  probed_codes="$probed_codes"$'unsafe_artifact_path\n'
  pass "unsafe_artifact_path -> 409 (unsafe diagnostic source path)"
else
  fail "unsafe_artifact_path -> $(status_of "$response") $(body_of "$response")"
fi
response="$(request POST /api/watch/start '{}' application/json)"
if [[ "$(status_of "$response")" == "200" ]]; then
  pass "watch start -> 200 on the watch-capable stub"
else
  fail "watch start -> $(status_of "$response") $(body_of "$response")"
fi
refused=0
for _ in $(seq 1 30); do
  state="$(request GET /api/watch/state)"
  if body_of "$state" | grep -q 'watch event schema'; then
    refused=1
    break
  fi
  sleep 0.1
done
if [[ "$refused" == "1" ]]; then
  pass "unsupported hello schema is reported in last_error"
else
  fail "the host never ingested the unsupported hello: $(body_of "$state")"
fi
response="$(request POST /api/watch/start '{}' application/json)"
if [[ "$(status_of "$response")" == "409" ]] && body_of "$response" | grep -q '"error":"watch_schema_unsupported"'; then
  probed_codes="$probed_codes"$'watch_schema_unsupported\n'
  pass "watch_schema_unsupported -> 409"
else
  fail "watch_schema_unsupported -> $(status_of "$response") $(body_of "$response")"
fi
stop_host

# --- §7.3: the bounded event ring -------------------------------------------

# The ring keeps at most 100 events and ~4 MiB, evicting the oldest. Nothing
# else in the gate drives it past either bound, and the eviction contract
# (`gap`, `oldest_seq`, `dropped_lines`) is only observable once it has. Two
# stubs flood their project's spool; the floods are separated by scenario so the
# count-cap and byte-cap states are both observable without a race.
note "bounded event ring: count cap, byte cap, gap, oldest_seq, dropped_lines"

# Count cap: one supported hello, one unparseable line, then 250 events. The
# ring must hold the newest 100, the bad line must count in `dropped_lines`
# without consuming a seq, and `gap` must be true for a cursor at 0.
flood_project="$work/flood-project"
"$boris_bin" init "$flood_project" >/dev/null 2>&1
cat >"$work/stub-flood-boris" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo "boris/9.9.9" ;;
  watch)
    case "$2" in
      --help) echo "--watch-json" ;;
      *)
        printf '{"event":"hello","watch_events_schema":1,"compiler":"boris/9.9.9"}\n' >&2
        printf 'this line is not json\n' >&2
        i=0
        while [ "$i" -lt 250 ]; do
          printf '{"event":"note","n":%s}\n' "$i" >&2
          i=$((i + 1))
        done
        exec sleep 5
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$work/stub-flood-boris"
start_host "$work/stub-flood-boris" flood.log "$flood_project"
response="$(request POST /api/watch/start '{}' application/json)"
if [[ "$(status_of "$response")" == "200" ]]; then
  pass "event-ring stub: watch start -> 200"
else
  fail "event-ring stub: watch start -> $(status_of "$response") $(body_of "$response")"
fi
count_target=251
state=""
for _ in $(seq 1 100); do
  state="$(request GET /api/watch/state)"
  seq_now="$(number_of seq "$(body_of "$state")")"
  [[ -n "$seq_now" && "$seq_now" -ge "$count_target" ]] && break
  sleep 0.1
done
body="$(body_of "$state")"
if [[ "$(number_of seq "$body")" == "$count_target" ]]; then
  pass "event ring: the unparseable line consumed no seq (1 hello + 250 events = $count_target)"
else
  fail "event ring: seq $(number_of seq "$body"), expected $count_target"
fi
if [[ "$(number_of dropped_lines "$body")" == "1" ]]; then
  pass "event ring: dropped_lines counts the unparseable line"
else
  fail "event ring: dropped_lines $(number_of dropped_lines "$body"), expected 1"
fi
if [[ "$(number_of events_count "$body")" == "100" ]]; then
  pass "event ring: the count cap holds 100 events"
else
  fail "event ring: events_count $(number_of events_count "$body"), expected 100"
fi
if [[ "$(number_of oldest_seq "$body")" == "152" ]]; then
  pass "event ring: oldest retained seq is 152 ($count_target - 100 + 1)"
else
  fail "event ring: oldest_seq $(number_of oldest_seq "$body"), expected 152"
fi

# A cursor at 0 cannot see the evicted head: `gap` must be true, `oldest_seq`
# must name the boundary the client resyncs from, and the window must be the
# full ring starting there.
response="$(request GET '/api/watch/events?after=0')"
events_body="$(body_of "$response")"
if [[ "$(bool_of gap "$events_body")" == "true" && "$(number_of oldest_seq "$events_body")" == "152" ]]; then
  pass "event ring: after=0 reports gap:true with oldest_seq 152"
else
  fail "event ring: after=0 gap/oldest_seq wrong: $events_body"
fi
if printf '%s' "$events_body" | grep -qF '"events":[{"seq":152,'; then
  pass "event ring: the window starts at the oldest retained event"
else
  fail "event ring: window does not start at seq 152"
fi
returned_count="$(printf '%s' "$events_body" | grep -o '"n":' | wc -l | tr -d ' ')"
if [[ "$returned_count" == "100" ]]; then
  pass "event ring: the window carries all 100 retained events"
else
  fail "event ring: returned $returned_count events, expected 100"
fi

# A cursor just behind the newest event has missed nothing: `gap` means "events
# you asked for were evicted", not "the ring is full".
response="$(request GET '/api/watch/events?after=250')"
events_body="$(body_of "$response")"
if [[ "$(bool_of gap "$events_body")" == "false" && "$(number_of seq "$events_body")" == "$count_target" ]]; then
  pass "event ring: after=250 reports gap:false"
else
  fail "event ring: after=250 gap/seq wrong: $events_body"
fi
stop_host

# Byte cap: the same flood idea with 80 x ~64 KiB events (~5 MiB total). None
# of them is oversized or unparseable, so `dropped_lines` must stay 0; the ~4
# MiB budget — not the 100-event cap — is what evicts, leaving fewer than 100.
byte_project="$work/byte-project"
"$boris_bin" init "$byte_project" >/dev/null 2>&1
cat >"$work/stub-byte-boris" <<'STUB'
#!/bin/sh
case "$1" in
  --version) echo "boris/9.9.9" ;;
  watch)
    case "$2" in
      --help) echo "--watch-json" ;;
      *)
        printf '{"event":"hello","watch_events_schema":1,"compiler":"boris/9.9.9"}\n' >&2
        pad="$(head -c 65536 /dev/zero | tr '\0' x)"
        i=0
        while [ "$i" -lt 80 ]; do
          printf '{"event":"chunk","pad":"%s"}\n' "$pad" >&2
          i=$((i + 1))
        done
        exec sleep 5
        ;;
    esac
    ;;
esac
exit 0
STUB
chmod +x "$work/stub-byte-boris"
start_host "$work/stub-byte-boris" byte.log "$byte_project"
response="$(request POST /api/watch/start '{}' application/json)"
if [[ "$(status_of "$response")" == "200" ]]; then
  pass "byte-cap stub: watch start -> 200"
else
  fail "byte-cap stub: watch start -> $(status_of "$response") $(body_of "$response")"
fi
byte_target=81
state=""
for _ in $(seq 1 200); do
  state="$(request GET /api/watch/state)"
  seq_now="$(number_of seq "$(body_of "$state")")"
  [[ -n "$seq_now" && "$seq_now" -ge "$byte_target" ]] && break
  sleep 0.1
done
body="$(body_of "$state")"
if [[ "$(number_of seq "$body")" == "$byte_target" ]]; then
  pass "event ring: the ~5 MiB flood was ingested ($byte_target events)"
else
  fail "event ring: byte-flood seq $(number_of seq "$body"), expected $byte_target"
fi
# 81 events can never trip the 100-event cap, so any loss here is the ~4 MiB
# byte budget evicting the head — and it must not have thrown away everything.
retained="$(number_of events_count "$body")"
if [[ -n "$retained" && "$retained" -gt 0 && "$retained" -lt "$byte_target" ]]; then
  pass "event ring: the ~4 MiB byte budget evicts below both caps ($retained of $byte_target retained, ~63 expected)"
else
  fail "event ring: byte cap did not bind (events_count $retained of $byte_target)"
fi
oldest="$(number_of oldest_seq "$body")"
if [[ -n "$oldest" && "$oldest" -gt 2 ]]; then
  pass "event ring: the byte cap evicted the head (oldest retained seq $oldest)"
else
  fail "event ring: oldest_seq $(number_of oldest_seq "$body") does not show a byte-driven eviction"
fi
if [[ "$(number_of dropped_lines "$body")" == "0" ]]; then
  pass "event ring: large-but-parseable events are not dropped"
else
  fail "event ring: dropped_lines $(number_of dropped_lines "$body"), expected 0"
fi
stop_host

# too_many_files: the file list is capped at 50 000 entries. The fixture is one
# `split` process writing one-byte files — a couple of seconds, not 50 000 shell
# iterations.
many_project="$work/many-project"
"$boris_bin" init "$many_project" >/dev/null 2>&1
mkdir -p "$many_project/content/many"
head -c 50100 /dev/zero | split -b 1 -d -a 5 - "$many_project/content/many/f"
many_count="$(find "$many_project/content/many" -type f | wc -l | tr -d ' ')"
if [[ "$many_count" -gt 50000 ]]; then
  pass "fixture: $many_count files under content/"
else
  fail "fixture: expected more than 50 000 files, found $many_count"
fi
start_host "$boris_bin" many.log "$many_project"
response="$(request GET /api/files)"
if [[ "$(status_of "$response")" == "413" ]] && body_of "$response" | grep -q '"error":"too_many_files"'; then
  probed_codes="$probed_codes"$'too_many_files\n'
  pass "too_many_files -> 413"
else
  fail "too_many_files -> $(status_of "$response")"
fi
stop_host

# --- coverage report --------------------------------------------------------

# No allowances: every code in §9 must have been produced by a live request
# above. A documented code that no request can raise is a contract defect —
# produce it or remove it — so this is a hard failure, never a skip list.
note "error-code coverage"
total_codes="$(printf '%s\n' "$DOCUMENTED_CODES" | grep -c .)"
missing_coverage=0
while IFS= read -r code; do
  [[ -n "$code" ]] || continue
  if printf '%s' "$probed_codes" | grep -qx "$code"; then
    continue
  fi
  missing_coverage=$((missing_coverage + 1))
  fail "$code is documented but no live request produced it"
done <<<"$DOCUMENTED_CODES"
[[ "$missing_coverage" -eq 0 ]] && pass "all $total_codes documented error codes driven live"

if [[ "$failures" -ne 0 ]]; then
  printf 'editor host contract conformance: FAILED (%d drift finding(s))\n' "$failures" >&2
  exit 1
fi
printf 'editor host contract conformance: ok (%d endpoints, %d undocumented probes rejected, %d error codes)\n' \
  "$route_count" "$undocumented_count" "$total_codes"
