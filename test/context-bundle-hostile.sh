#!/usr/bin/env bash
# Focused black-box hostile coverage for the Context Bundle contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

zig build
BORIS="${ROOT}/zig-out/bin/boris"
FIXTURE="docs/contracts/fixtures/context-bundle-hostile/content"
INVALID="docs/contracts/fixtures/semantic-relations-invalid/content"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/boris-context-hostile.XXXXXX")"
trap 'rm -rf "${TMP}"' EXIT

first="${TMP}/first"
second="${TMP}/second"
"${BORIS}" --context --context-dir="${first}" --input="${FIXTURE}" --quiet
"${BORIS}" --context --context-dir="${second}" --input="${FIXTURE}" --quiet

# Repeat exports are byte-identical and source provenance never includes this host root.
diff -rq "${first}" "${second}" >/dev/null
if rg -F --quiet "${ROOT}" "${first}"; then
  echo "context bundle leaked an absolute host path" >&2
  exit 1
fi

# Semantic relations remain in graph output and source fences outgrow source fences.
grep -q '"relations": \[' "${first}/graph.json"
grep -q '"kind": "supersedes"' "${first}/graph.json"
grep -q '"value": "guides/current"' "${first}/graph.json"
grep -q '"value": "guides/previous"' "${first}/graph.json"
grep -q '^``````markdown$' "${first}/pages/guides/current.md"

# A validation failure does not replace the prior complete bundle or leave staging behind.
before="$(shasum -a 256 "${first}/manifest.json")"
if "${BORIS}" --context --context-dir="${first}" --input="${INVALID}" --quiet; then
  echo "invalid context input unexpectedly succeeded" >&2
  exit 1
fi
after="$(shasum -a 256 "${first}/manifest.json")"
test "${before}" = "${after}"
test ! -e "${first}.boris-context-stage"
test ! -e "${second}.boris-context-stage"
