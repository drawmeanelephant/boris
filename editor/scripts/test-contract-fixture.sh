#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 BORIS_BIN CONTRACT_PROBE" >&2
  exit 2
fi

boris_bin="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
probe_bin="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
work="$(mktemp -d "${TMPDIR:-/tmp}/boris-editor-contract.XXXXXX")"
trap 'rm -rf -- "$work"' EXIT

for run in one two; do
  project="$work/$run"
  "$boris_bin" init "$project" >/dev/null
  (
    cd "$project"
    "$boris_bin" build --out .boris --quiet
    "$boris_bin" check --input content --format json --report check.json >/dev/null
    "$boris_bin" plan --profile boris.json > plan.json
  )
  "$probe_bin" \
    "$project/.boris" \
    "$project/check.json" \
    "$project/plan.json" \
    "$repo_root/docs/contracts/schemas/boris-frontmatter-1.schema.json"
done

for artifact in manifest.json graph.json completion.json build-report.json; do
  cmp "$work/one/.boris/$artifact" "$work/two/.boris/$artifact"
done
cmp "$work/one/check.json" "$work/two/check.json"
cmp "$work/one/plan.json" "$work/two/plan.json"

echo "editor contract fixture: ok"
