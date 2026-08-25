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
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-cooklang.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

mkdir -p "$work/project"
cp -R "$repo_root/docs/contracts/fixtures/cooklang-compatibility/content" "$work/project/content"
printf '{}\n' >"$work/project/boris.json"

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

health="$(api_get /api/health)"
node -e 'const h=JSON.parse(process.argv[1]); if(h.project.input_mode!=="cooklang") throw Error("expected cooklang input_mode, got "+h.project.input_mode)' "$health"

built="$(api_post /api/commands/run '{"mode":"ir_build"}')"
node -e 'const r=JSON.parse(process.argv[1]); if(r.exit_code!==0||r.failure_class!=="success") throw Error("cooklang IR build failed: "+JSON.stringify(r))' "$built"

api_get /api/graph >"$work/graph.json"
node -e '
  const fs = require("fs");
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const artifact = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (payload.graph_status !== "ready") throw Error("graph not ready after cooklang build");
  if (JSON.stringify(payload.graph) !== JSON.stringify(artifact)) throw Error("graph payload differs from Boris graph.json");
  const carbonara = payload.graph.nodes.find(n => n.id === "carbonara");
  if (!carbonara || !carbonara.recipe) throw Error("carbonara recipe facet missing");
  const ref = carbonara.recipe.ingredients.find(i => i.recipeRef === "sauces/pepper-oil");
  if (!ref) throw Error("recipeRef sauces/pepper-oil missing from facet");
' "$work/graph.json" "$work/project/.boris/graph.json"

before_hash="$(cksum "$work/project/content/carbonara.cook")"
scaled="$(api_post /api/commands/run '{"mode":"recipe_scale","recipe_scale_id":"carbonara","recipe_scale_factor":"2"}')"
node -e '
  const r = JSON.parse(process.argv[1]);
  if (r.exit_code !== 0 || r.failure_class !== "success") throw Error("recipe-scale failed: " + JSON.stringify(r));
  const view = r.recipe_scale_view;
  if (!view || view.format !== "boris-recipe-scale" || view.page !== "carbonara") throw Error("missing scaled view");
  const spaghetti = view.ingredients.find(i => i.name === "spaghetti");
  if (!spaghetti || spaghetti.quantity.amount.original !== "400" || spaghetti.quantity.amount.scaled !== "800") {
    throw Error("spaghetti did not double: " + JSON.stringify(spaghetti));
  }
  const pasta = view.timers.find(t => t.name === "pasta");
  if (!pasta || pasta.quantity.amount.scaled !== pasta.quantity.amount.original) {
    throw Error("pasta timer scaled: " + JSON.stringify(pasta));
  }
' "$scaled"
after_hash="$(cksum "$work/project/content/carbonara.cook")"
if [[ "$before_hash" != "$after_hash" ]]; then
  echo "recipe-scale rewrote carbonara.cook" >&2
  exit 1
fi

echo "editor Cooklang integration: ok"
