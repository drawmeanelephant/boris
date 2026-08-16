#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "usage: $0 BORIS_BIN EDITOR_BIN UI_DIR" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
editor_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
ui_dir="$(cd "$3" && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-publication.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$boris_bin" init "$work/project" >/dev/null
cp "$repo_root/docs/contracts/fixtures/publication-plan/github-pages/profile.json" "$work/project/pages.json"
mkdir -p "$work/project/dist/_boris/proof"
cat >"$work/project/dist/_boris/proof/proof-pack.json" <<'JSON'
{"format":"boris-publication-proof-pack","schema_version":1,"target":"public","summary":{"artifacts":{"total":2},"checks":{"total":3},"findings":{"total":0},"claims":{"total":3},"overall_presentation_status":"verified"}}
JSON
printf '<html></html>\n' >"$work/project/dist/_boris/proof/index.html"

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

api_get() {
  curl --fail --silent --show-error -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" "$base_url$1"
}
api_post() {
  curl --fail --silent --show-error -H "Host: 127.0.0.1:$port" -H "X-Boris-Editor-Token: $token" -H 'Content-Type: application/json' --data "$2" "$base_url$1"
}

payload="$(api_get /api/publication)"
node -e '
  const p = JSON.parse(process.argv[1]);
  const paths = p.profiles.map(profile => profile.path).sort();
  if (!paths.includes("boris.json") || !paths.includes("standard-site.json") || !paths.includes("pages.json")) {
    throw Error("expected init + copied profiles, got " + JSON.stringify(paths));
  }
  if (!p.proof || p.proof.target !== "public" || p.proof.overall_presentation_status !== "verified") {
    throw Error("expected local Proof Pack summary, got " + JSON.stringify(p.proof));
  }
  if (p.proof.path !== "dist/_boris/proof/proof-pack.json") throw Error("unexpected proof path");
' "$payload"

pages="$(api_post /api/commands/run '{"mode":"plan","profile":"pages.json"}')"
node -e '
  const r = JSON.parse(process.argv[1]);
  if (r.mode !== "plan" || r.exit_code !== 0 || r.failure_class !== "success") {
    throw Error("pages plan failed: " + JSON.stringify(r));
  }
  const plan = r.publication_plan;
  if (!plan || plan.format !== "boris-publication-plan" || plan.publication?.target !== "github-pages") {
    throw Error("expected github-pages declaration, got " + JSON.stringify(plan));
  }
  if (plan.publication.base_url !== "https://owner.github.io/boris") {
    throw Error("plan location drifted: " + JSON.stringify(plan.publication));
  }
' "$pages"

starter="$(api_post /api/commands/run '{"mode":"plan","profile":"boris.json"}')"
node -e '
  const r = JSON.parse(process.argv[1]);
  if (r.exit_code !== 0 || !r.publication_plan) throw Error("starter plan failed: " + JSON.stringify(r));
  if (r.publication_plan.publication != null) throw Error("starter profile is not a hosted identity");
' "$starter"

echo "editor publication integration: ok"
