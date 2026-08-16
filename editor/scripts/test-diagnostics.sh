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
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-diagnostics.XXXXXX")"
editor_pid=""
cleanup() {
  if [[ -n "$editor_pid" ]]; then kill "$editor_pid" 2>/dev/null || true; fi
  rm -rf -- "$work"
}
trap cleanup EXIT

"$boris_bin" init "$work/project" >/dev/null
cp "$repo_root/fixtures/content/invalid/duplicate-id/a.md" "$work/project/content/a.md"
cp "$repo_root/fixtures/content/invalid/duplicate-id/b.md" "$work/project/content/b.md"

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

run_command() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    -H 'Content-Type: application/json' \
    --data "$2" "$base_url/api/commands/run" >"$1"
}

get_api() {
  curl --fail --silent --show-error \
    -H "Host: 127.0.0.1:$port" \
    -H "X-Boris-Editor-Token: $token" \
    "$base_url$2" >"$1"
}

run_command "$work/ir-invalid.json" '{"mode":"ir_build"}'
node -e '
  const fs = require("fs");
  const result = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (result.exit_code !== 1 || result.failure_class !== "content" || result.used_stderr_fallback) throw Error("IR exit classification/fallback mismatch");
  const actual = result.problems.map(({severity,code,message,remediation,source_path,line,column,id}) => ({severity,code,message,remediation,sourcePath:source_path,line,column,id}));
  if (JSON.stringify(actual) !== JSON.stringify(report.diagnostics)) throw Error("host diagnostics differ from Boris build-report.json");
  if (result.problems.some(p => p.origin !== "build_report" || p.position_confidence !== "exact" || p.packet.length > 4096 || p.packet.includes(process.argv[3]))) throw Error("structured diagnostic provenance or packet safety mismatch");
' "$work/ir-invalid.json" "$work/project/.boris/build-report.json" "$work/project"

run_command "$work/validate-invalid.json" '{"mode":"validate"}'
node -e '
  const fs = require("fs");
  const r = require(process.argv[1]);
  const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const p = r.problems.find(p => p.code === "EDUPLICATEID");
  if (r.exit_code !== 1 || r.failure_class !== "content" || r.used_stderr_fallback || r.report_version !== "html-build-report-0.1.0") throw Error("validate HTML report mismatch");
  if (!p || p.source_path !== "b.md" || p.line !== 1 || p.column !== 1 || p.origin !== "build_report" || p.position_confidence !== "exact") throw Error("validate structured position mismatch");
  if (!report.diagnostics.some(d => d.code === "EDUPLICATEID")) throw Error("html-build-report.json missing EDUPLICATEID");
' "$work/validate-invalid.json" "$work/project/.boris/html-build-report.json"

rm "$work/project/content/a.md" "$work/project/content/b.md"
run_command "$work/ir-valid.json" '{"mode":"ir_build"}'
get_api "$work/authoring.json" '/api/authoring'
get_api "$work/graph.json" '/api/graph'
node -e '
  const fs = require("fs");
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const completion = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  const schema = JSON.parse(fs.readFileSync(process.argv[3], "utf8"));
  if (payload.completion_status !== "ready") throw Error("completion did not refresh after build");
  if (JSON.stringify(payload.completion) !== JSON.stringify(completion)) throw Error("completion payload differs from Boris artifact");
  if (JSON.stringify(payload.frontmatter_schema) !== JSON.stringify(schema)) throw Error("frontmatter payload differs from canonical Boris schema");
' "$work/authoring.json" "$work/project/.boris/completion.json" "$repo_root/docs/contracts/schemas/boris-frontmatter-1.schema.json"
node -e '
  const fs = require("fs");
  const payload = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const graph = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (payload.graph_status !== "ready") throw Error("graph did not refresh after build");
  if (JSON.stringify(payload.graph) !== JSON.stringify(graph)) throw Error("graph payload differs from Boris graph.json");
' "$work/graph.json" "$work/project/.boris/graph.json"

run_command "$work/check-valid.json" '{"mode":"check"}'
node -e '
  const r = require(process.argv[1]);
  if (r.exit_code !== 0 || r.failure_class !== "success" || r.used_stderr_fallback || !r.report_version || !Array.isArray(r.findings)) throw Error("check artifact adaptation mismatch");
' "$work/check-valid.json"

run_command "$work/impact-missing.json" '{"mode":"impact","impact_id":"does-not-exist"}'
node -e '
  const r = require(process.argv[1]);
  if (r.exit_code !== 2 || r.failure_class !== "usage") throw Error("exit 2 was not preserved");
' "$work/impact-missing.json"

mv "$work/project/content" "$work/project/content-away"
run_command "$work/io-failure.json" '{"mode":"validate"}'
mv "$work/project/content-away" "$work/project/content"
node -e '
  const r = require(process.argv[1]);
  if (r.exit_code !== 3 || r.failure_class !== "io") throw Error("exit 3 was not preserved");
' "$work/io-failure.json"

run_command "$work/html-valid.json" '{"mode":"html_build"}'
node -e '
  const fs = require("fs");
  const r = require(process.argv[1]);
  const report = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
  if (r.exit_code !== 0 || r.failure_class !== "success") throw Error("HTML build failed");
  if (r.used_stderr_fallback || r.report_version !== "html-build-report-0.1.0") throw Error("HTML report was not adapted");
  if (report.schemaVersion !== "html-build-report-0.1.0") throw Error("html-build-report.json missing");
' "$work/html-valid.json" "$work/project/.boris/html-build-report.json"
[[ -f "$work/project/dist/index.html" ]]

echo "editor Boris diagnostics integration: ok"
