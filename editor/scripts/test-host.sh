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
before="$(find "$work/project/content" -type f -print0 | sort -z | xargs -0 shasum -a 256)"
"$editor_bin" "$work/project" --boris "$boris_bin" --ui-dir "$ui_dir" --port 0 >"$work/host.log" 2>&1 &
editor_pid=$!

for _ in $(seq 1 100); do
  grep -q 'BORIS_EDITOR_URL=' "$work/host.log" && break
  kill -0 "$editor_pid" 2>/dev/null || { cat "$work/host.log" >&2; exit 1; }
  sleep 0.05
done

launch_url="$(sed -n 's/^BORIS_EDITOR_URL=//p' "$work/host.log" | head -1)"
[[ -n "$launch_url" ]]
base_url="${launch_url%%/#*}"
token="${launch_url##*#token=}"
port="$(printf '%s' "$base_url" | sed -E 's#.*:([0-9]+)$#\1#')"

curl --fail --silent --show-error "$base_url/" | grep -q '<title>Boris Editor</title>'
curl --fail --silent --show-error \
  -H "Host: 127.0.0.1:$port" \
  -H "X-Boris-Editor-Token: $token" \
  "$base_url/api/health" | grep -q '"status":"ok"'
curl --fail --silent --show-error \
  -H "Host: 127.0.0.1:$port" \
  -H "X-Boris-Editor-Token: $token" \
  "$base_url/api/version" | grep -q '"compiler_id":"boris/'

forbidden_code="$(curl --silent --output /dev/null --write-out '%{http_code}' \
  -H "Host: attacker.test:$port" \
  -H "X-Boris-Editor-Token: $token" \
  "$base_url/api/health")"
[[ "$forbidden_code" == "403" ]]
after="$(find "$work/project/content" -type f -print0 | sort -z | xargs -0 shasum -a 256)"
[[ "$before" == "$after" ]]

echo "editor host integration: ok"
