#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BORIS_BIN EDITOR_BIN UI_DIR" >&2
  exit 2
fi

boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
editor_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ui_dir="$(cd "$3" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-host.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$boris_bin" init "$work/project" >/dev/null
mkdir -p "$work/project/dist" "$work/project/.boris"
printf 'generated\n' >"$work/project/dist/index.html"
printf '{}\n' >"$work/project/.boris/graph.json"

start_editor() {
  : >"$work/host.log"
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
}

stop_editor() {
  kill "$editor_pid" 2>/dev/null || true
  wait "$editor_pid" 2>/dev/null || true
  editor_pid=""
}

api_get() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    "$base_url$1"
}

api_post() {
  curl --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    -H 'Content-Type: application/json' \
    --data "$2" \
    --write-out $'\n%{http_code}' \
    "$base_url$1"
}

body_of() { sed '$d'; }
code_of() { tail -1; }
fingerprint_of() { sed -n 's/.*"fingerprint":"\([0-9a-f]\{64\}\)".*/\1/p'; }

start_editor

curl --fail --silent --show-error "$base_url/" | grep -q '<title>Boris Editor</title>'
api_get /api/health | grep -q '"status":"ok"'
api_get /api/version | grep -q '"compiler_id":"boris/'

files="$(api_get /api/files)"
printf '%s' "$files" | grep -q '"path":"content/index.md"'
if printf '%s' "$files" | grep -Eq 'dist/index.html|\.boris/graph.json'; then
  echo "generated output escaped into the author file list" >&2
  exit 1
fi

# Planted "{}" graph.json is stale, not a 502. Profiles still load.
graph="$(api_get /api/graph)"
printf '%s' "$graph" | grep -q '"graph_status":"unsupported"'
printf '%s' "$graph" | grep -q '"graph":null'
version="$(api_get /api/version)"
printf '%s' "$version" | grep -q '"compiler_id":"boris/'
printf '%s' "$version" | grep -q '"publication_plan"'

opened="$(api_post /api/files/open '{"path":"content/index.md"}')"
[[ "$(printf '%s' "$opened" | code_of)" == "200" ]]
fingerprint="$(printf '%s' "$opened" | body_of | fingerprint_of)"
[[ ${#fingerprint} -eq 64 ]]

# An external write after open must produce a 409 and preserve both versions.
printf '# External edit\n' >"$work/project/content/index.md"
conflict="$(api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# My edit\\n\",\"fingerprint\":\"$fingerprint\"}")"
[[ "$(printf '%s' "$conflict" | code_of)" == "409" ]]
printf '%s' "$conflict" | body_of | grep -q '"status":"conflict"'
grep -q '^# External edit$' "$work/project/content/index.md"

# Retrying against the returned disk fingerprint is an explicit replacement.
external_fingerprint="$(printf '%s' "$conflict" | body_of | fingerprint_of)"
saved="$(api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# My edit\\n\",\"fingerprint\":\"$external_fingerprint\"}")"
[[ "$(printf '%s' "$saved" | code_of)" == "200" ]]
grep -q '^# My edit$' "$work/project/content/index.md"

# Recovery is durable across a host restart but remains outside project truth.
saved_fingerprint="$(printf '%s' "$saved" | body_of | fingerprint_of)"
snapshot="$(api_post /api/recovery/snapshot "{\"path\":\"content/index.md\",\"content\":\"# Unsaved after crash\\n\",\"fingerprint\":\"$saved_fingerprint\"}")"
[[ "$(printf '%s' "$snapshot" | code_of)" == "200" ]]
stop_editor
start_editor
api_get /api/recovery | grep -q 'Unsaved after crash'
cleared="$(api_post /api/recovery/clear '{"path":"content/index.md"}')"
[[ "$(printf '%s' "$cleared" | code_of)" == "200" ]]

# No-clobber create/rename and explicit delete semantics.
created="$(api_post /api/files/create '{"path":"content/existing.md","content":"keep\n"}')"
[[ "$(printf '%s' "$created" | code_of)" == "201" ]]
collision="$(api_post /api/files/rename '{"path":"content/index.md","new_path":"content/existing.md"}')"
[[ "$(printf '%s' "$collision" | code_of)" == "409" ]]
grep -q '^# My edit$' "$work/project/content/index.md"
grep -q '^keep$' "$work/project/content/existing.md"
unconfirmed="$(api_post /api/files/delete '{"path":"content/existing.md","confirmed":false}')"
[[ "$(printf '%s' "$unconfirmed" | code_of)" == "409" ]]
[[ -f "$work/project/content/existing.md" ]]
deleted="$(api_post /api/files/delete '{"path":"content/existing.md","confirmed":true}')"
[[ "$(printf '%s' "$deleted" | code_of)" == "200" ]]
[[ ! -e "$work/project/content/existing.md" ]]

# Deleted-on-disk and read-only files never get silently recreated/replaced.
opened="$(api_post /api/files/open '{"path":"content/index.md"}')"
fingerprint="$(printf '%s' "$opened" | body_of | fingerprint_of)"
rm "$work/project/content/index.md"
missing="$(api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# Recreate\\n\",\"fingerprint\":\"$fingerprint\"}")"
[[ "$(printf '%s' "$missing" | code_of)" == "409" ]]
printf '%s' "$missing" | body_of | grep -q '"status":"deleted"'
[[ ! -e "$work/project/content/index.md" ]]
recreated="$(api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# Recreate\\n\",\"fingerprint\":\"$fingerprint\",\"recreate\":true}")"
[[ "$(printf '%s' "$recreated" | code_of)" == "200" ]]
fingerprint="$(printf '%s' "$recreated" | body_of | fingerprint_of)"
chmod 444 "$work/project/content/index.md"
readonly="$(api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# Forbidden\\n\",\"fingerprint\":\"$fingerprint\"}")"
[[ "$(printf '%s' "$readonly" | code_of)" == "409" ]]
printf '%s' "$readonly" | body_of | grep -q '"error":"read_only"'
grep -q '^# Recreate$' "$work/project/content/index.md"
chmod 644 "$work/project/content/index.md"

traversal="$(api_post /api/files/open '{"path":"../secret"}')"
[[ "$(printf '%s' "$traversal" | code_of)" == "400" ]]
forbidden_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Host: attacker.test:$port" \
  -H "X-Boris-Editor-Token: $token" \
  "$base_url/api/files")"
[[ "$forbidden_code" == "403" ]]

echo "editor host safe-editing integration: ok"
