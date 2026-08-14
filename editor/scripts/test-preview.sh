#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BORIS_BIN EDITOR_BIN UI_DIR" >&2
  exit 2
fi

boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
editor_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ui_dir="$(cd "$3" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-preview.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$boris_bin" init "$work/project" >/dev/null
"$editor_bin" "$work/project" --boris "$boris_bin" --ui-dir "$ui_dir" --port 0 >"$work/host.log" 2>&1 &
editor_pid=$!
for _ in $(seq 1 100); do
  grep -q 'BORIS_EDITOR_URL=' "$work/host.log" && break
  kill -0 "$editor_pid" 2>/dev/null || { sed -n '1,120p' "$work/host.log" >&2; exit 1; }
  sleep 0.05
done
launch_url="$(sed -n 's/^BORIS_EDITOR_URL=//p' "$work/host.log" | head -1)"
base_url="${launch_url%%/#*}"
token="${launch_url##*#token=}"
port="$(printf '%s' "$base_url" | sed -E 's#.*:([0-9]+)$#\1#')"

api_get() {
  curl --fail --silent --show-error -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" "$base_url$1"
}
api_post() {
  curl --fail --silent --show-error -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" -H 'Content-Type: application/json' --data "$2" "$base_url$1"
}

initial="$(api_get /api/preview/state)"
node -e 'const r=JSON.parse(process.argv[1]); if(r.phase!=="idle"||r.generation!==0) throw Error("preview did not start idle")' "$initial"

current="$(api_post /api/preview/rebuild '{}')"
node -e 'const r=JSON.parse(process.argv[1]); if(r.phase!=="success"||r.generation!==1||r.exit_code!==0) throw Error("first preview build failed")' "$current"
preview_url="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).preview_url)' "$current")"
preview_origin="$(node -e 'process.stdout.write(new URL(process.argv[1]).origin)' "$preview_url")"

unauthorized="$(curl --silent --output /dev/null --write-out '%{http_code}' "$preview_origin/")"
[[ "$unauthorized" == "403" ]]
bad_host="$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Host: attacker.test' "$preview_url")"
[[ "$bad_host" == "403" ]]
bad_origin="$(curl --silent --output /dev/null --write-out '%{http_code}' -H 'Origin: https://attacker.test' "$preview_url")"
[[ "$bad_origin" == "403" ]]
curl --fail --silent --show-error --cookie-jar "$work/cookies" "$preview_url" >"$work/served.html"
cmp "$work/served.html" "$work/project/dist/index.html"

(cd "$work/project" && "$boris_bin" build --input content --html-dir expected >/dev/null)
cmp "$work/project/dist/index.html" "$work/project/expected/index.html"
traversal="$(curl --path-as-is --silent --output /dev/null --write-out '%{http_code}' --cookie "$work/cookies" "$preview_origin/%2e%2e/boris.json")"
[[ "$traversal" == "400" ]]

opened="$(api_post /api/files/open '{"path":"content/index.md"}')"
fingerprint="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).fingerprint)' "$opened")"
saved="$(api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"# Preview changed\\n\",\"fingerprint\":\"$fingerprint\"}")"
node -e 'const r=JSON.parse(process.argv[1]); if(r.status!=="saved") throw Error("source save failed")' "$saved"
current="$(api_post /api/preview/rebuild '{}')"
node -e 'const r=JSON.parse(process.argv[1]); if(r.phase!=="success"||r.generation!==2) throw Error("save rebuild did not advance")' "$current"
curl --fail --silent --show-error --cookie "$work/cookies" "$preview_origin/" >"$work/last-good.html"
grep -q 'Preview changed' "$work/last-good.html"

NODE_PATH="$(dirname "$3")/node_modules" node "$(dirname "$0")/preview-frame-check.cjs" "$base_url/#token=$token" "Preview changed"

stale_state="$(api_get /api/preview/state)"
stale_generation="$(node -e 'process.stdout.write(String(JSON.parse(process.argv[1]).generation))' "$stale_state")"

opened="$(api_post /api/files/open '{"path":"content/index.md"}')"
fingerprint="$(node -e 'process.stdout.write(JSON.parse(process.argv[1]).fingerprint)' "$opened")"
api_post /api/files/save "{\"path\":\"content/index.md\",\"content\":\"---\\nid: broken\\n\",\"fingerprint\":\"$fingerprint\"}" >/dev/null
failed="$(api_post /api/preview/rebuild '{}')"
node -e 'const r=JSON.parse(process.argv[1]); if(r.phase!=="stale"||r.generation!==Number(process.argv[2])||r.exit_code!==1||!r.used_stderr_fallback||!r.message.includes("error:")) throw Error("failure state was not honest")' "$failed" "$stale_generation"
curl --fail --silent --show-error --cookie "$work/cookies" "$preview_origin/" >"$work/after-failure.html"
cmp "$work/last-good.html" "$work/after-failure.html"

kill "$editor_pid"
wait "$editor_pid" 2>/dev/null || true
editor_pid=""
stopped="$(curl --silent --output /dev/null --write-out '%{http_code}' --max-time 1 "$preview_origin/" || true)"
[[ "$stopped" == "000" ]]

echo "editor live preview integration: ok"
