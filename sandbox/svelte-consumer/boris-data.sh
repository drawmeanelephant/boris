#!/usr/bin/env bash
# TEMPORARY GLUE (spike) — runs Boris to regenerate the data/ directory that
# the SvelteKit app consumes. Two invocations because the Boris CLI keeps
# HTML and IR modes separate (exit 2 if combined):
#
#   1. IR mode:            manifest.json + graph.json + build-report.json
#   2. HTML mode:          body fragments via a {{content}}-only layout
#
# The body-fragment trick is NOT new Boris behavior — it is the existing
# --html-layout mechanism (layouts are user-authored, framework-neutral HTML).
# All content comes from the Boris repo's real content/ tree; nothing here is
# invented for Svelte.
#
# Run from anywhere:   bash sandbox/svelte-consumer/boris-data.sh
# (or: npm run data   from sandbox/svelte-consumer)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BIN="${REPO_ROOT}/zig-out/bin/boris"

# Boris rejects absolute layout paths and records whatever path strings it is
# given (determinism), so always invoke it from the repo root with relative
# paths.
cd "${REPO_ROOT}"
SUB="${SCRIPT_DIR#"${REPO_ROOT}/"}"   # e.g. sandbox/svelte-consumer
DATA_REL="${SUB}/data"
LAYOUT_REL="${SUB}/layouts/content-only.html"

if [[ ! -x "${BIN}" ]]; then
  echo "Boris binary not found at ${BIN} — build it first: zig build (repo root)" >&2
  exit 1
fi

# Cross-command snapshot consistency (docs/contracts/consumer-feed.md §2):
# build BOTH outputs into a fresh staging dir, and only after both succeed
# replace the published feed in one rename. With `set -e`, any failure aborts
# before the swap, so the previously published feed stays intact — never a
# half-updated data/ (IR from one content state, bodies from another).
STAGE_REL="${DATA_REL}.stage"
rm -rf "${STAGE_REL}" 2>/dev/null || true
mkdir -p "${STAGE_REL}/bodies"

"${BIN}" --out "${STAGE_REL}" --quiet
"${BIN}" --html-dir "${STAGE_REL}/bodies" --html-layout "${LAYOUT_REL}" --quiet

# Swap with a recovery path: move the previous feed aside (never delete it
# first), move the staged feed into place, and only then drop the previous
# one. If the in-place rename fails, restore the previous feed instead of
# leaving the consumer without one. The signal trap covers interruption
# (SIGINT/SIGTERM) between the two renames, and the EXIT trap covers every
# exit path (consumer-feed.md §2 "Snapshot consistency").
#
# restore_prev_feed reports HONESTLY: it returns success only when the
# previous feed is actually back in place, and every caller prints a loud
# error naming the recovery path if it is not — never a false "restored".
SWAP_IN_PROGRESS=0
restore_prev_feed() {
  if [[ "${SWAP_IN_PROGRESS}" == 1 && -d "${DATA_REL}.prev" && ! -d "${DATA_REL}" ]]; then
    mv "${DATA_REL}.prev" "${DATA_REL}" 2>/dev/null
    return $?
  fi
  return 0
}
fail_restore() {
  echo "error: could not restore the previous feed — data/ is missing; recover ${DATA_REL}.prev manually" >&2
}
trap 'if ! restore_prev_feed; then fail_restore; fi' EXIT
trap 'if ! restore_prev_feed; then fail_restore; fi; exit 130' INT TERM

SWAP_IN_PROGRESS=1
rm -rf "${DATA_REL}.prev" 2>/dev/null || true
if [[ -d "${DATA_REL}" ]]; then
  mv "${DATA_REL}" "${DATA_REL}.prev"
fi
if ! mv "${STAGE_REL}" "${DATA_REL}"; then
  if restore_prev_feed; then
    echo "error: feed swap failed; previous feed restored" >&2
  else
    fail_restore
  fi
  exit 1
fi
SWAP_IN_PROGRESS=0
rm -rf "${DATA_REL}.prev"

# Publish the IR into the Svelte app's static tree so the site itself exposes
# machine-readable content endpoints (/boris/manifest.json, /boris/graph.json).
mkdir -p "${SCRIPT_DIR}/static/boris"
cp "${SCRIPT_DIR}/data/manifest.json" "${SCRIPT_DIR}/data/graph.json" "${SCRIPT_DIR}/data/build-report.json" "${SCRIPT_DIR}/static/boris/"

# Content-local page assets: Boris publishes them into the body feed under
# {entity_id}.assets/ (content-local-assets.md). Copy those trees to static/
# so the page-relative URLs (e.g. /guides/overview.assets/spike.svg) resolve
# in the Svelte app. No-op when the corpus has no assets. See the experiment
# report — consumer glue, not a Boris gap.
while IFS= read -r d; do
  rel="${d#"${SCRIPT_DIR}/data/bodies/"}"
  mkdir -p "${SCRIPT_DIR}/static/$(dirname "${rel}")"
  cp -R "${d}" "${SCRIPT_DIR}/static/$(dirname "${rel}")/"
done < <(find "${SCRIPT_DIR}/data/bodies" -type d -name '*.assets' 2>/dev/null)

echo "ok: Boris IR + body fragments -> ${DATA_REL}, published to static/boris"
