#!/usr/bin/env bash
# Black-box coverage for authoritative, no-publication Boris validation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BORIS="${1:-${ROOT}/zig-out/bin/boris}"
if [[ ! -x "${BORIS}" ]]; then
  zig build
fi

LAYOUT="test/fixtures/layouts/ok.html"
VALID="docs/contracts/fixtures/valid/content"
TMP="${ROOT}/.release-gate-validate-contract-${$}"
rm -rf "${TMP}"
mkdir -p "${TMP}/logs"
trap 'rm -rf "${TMP}"' EXIT

run_expect() {
  local expected="$1"
  local stdout_path="$2"
  local stderr_path="$3"
  shift 3
  set +e
  "$@" >"${stdout_path}" 2>"${stderr_path}"
  local actual=$?
  set -e
  if [[ "${actual}" -ne "${expected}" ]]; then
    printf 'expected exit %s, got %s: %s\n' "${expected}" "${actual}" "$*" >&2
    sed -n '1,120p' "${stderr_path}" >&2
    exit 1
  fi
}

assert_no_target() {
  local output="$1"
  test ! -e "${output}"
  test ! -e "${output}.boris-stage"
}

run_invalid_fixture() {
  local name="$1"
  local fixture="$2"
  local code="$3"
  local output="${TMP}/${name}-output"
  run_expect 1 "${TMP}/logs/${name}.stdout" "${TMP}/logs/${name}.stderr" \
    "${BORIS}" validate --input="${fixture}" --html-layout="${LAYOUT}" \
    --html-dir="${output}"
  grep -q "${code}" "${TMP}/logs/${name}.stderr"
  test ! -s "${TMP}/logs/${name}.stdout"
  assert_no_target "${output}"
}

# Success is silent under --quiet, deterministic across runs, and creates no
# target, stage, cache, search, IR, or publication-evidence tree.
VALID_OUT="${TMP}/valid-output"
run_expect 0 "${TMP}/logs/valid-a.stdout" "${TMP}/logs/valid-a.stderr" \
  "${BORIS}" validate --input="${VALID}" --html-layout="${LAYOUT}" \
  --html-dir="${VALID_OUT}" --sitemap --site-url="https://example.test/docs/" --quiet
assert_no_target "${VALID_OUT}"
run_expect 0 "${TMP}/logs/valid-b.stdout" "${TMP}/logs/valid-b.stderr" \
  "${BORIS}" validate --input="${VALID}" --html-layout="${LAYOUT}" \
  --html-dir="${VALID_OUT}" --sitemap --site-url="https://example.test/docs/" --quiet
assert_no_target "${VALID_OUT}"
cmp "${TMP}/logs/valid-a.stdout" "${TMP}/logs/valid-b.stdout"
cmp "${TMP}/logs/valid-a.stderr" "${TMP}/logs/valid-b.stderr"
test ! -s "${TMP}/logs/valid-a.stdout"
test ! -s "${TMP}/logs/valid-a.stderr"

# Existing multi-target, theme, and Textile vocabulary reaches the same
# no-publication path rather than a parallel validation configuration surface.
MULTI_A="${TMP}/multi-a"
MULTI_B="${TMP}/multi-b"
run_expect 0 "${TMP}/logs/multi.stdout" "${TMP}/logs/multi.stderr" \
  "${BORIS}" validate --input="${VALID}" --html-layout="${LAYOUT}" \
  --target="a=${MULTI_A}" --target="b=${MULTI_B}" --quiet
assert_no_target "${MULTI_A}"
assert_no_target "${MULTI_B}"

THEME_OUT="${TMP}/theme-output"
run_expect 0 "${TMP}/logs/theme.stdout" "${TMP}/logs/theme.stderr" \
  "${BORIS}" validate --input="docs/contracts/fixtures/theme-site/content" \
  --theme="docs/contracts/fixtures/theme-site/experimental-theme" \
  --html-dir="${THEME_OUT}" --quiet
assert_no_target "${THEME_OUT}"

TEXTILE_OUT="${TMP}/textile-output"
run_expect 0 "${TMP}/logs/textile.stdout" "${TMP}/logs/textile.stderr" \
  "${BORIS}" validate --textile \
  --input="docs/contracts/fixtures/textile-compatibility/content" \
  --html-layout="${LAYOUT}" --html-dir="${TEXTILE_OUT}" --quiet
assert_no_target "${TEXTILE_OUT}"

# An existing target is observed for isolation checks but remains byte-for-byte
# untouched; validation does not scrub, stage, cache, or add evidence to it.
EXISTING_OUT="${TMP}/existing-output"
mkdir -p "${EXISTING_OUT}"
printf 'foreign sentinel\n' >"${EXISTING_OUT}/sentinel.txt"
run_expect 0 "${TMP}/logs/existing.stdout" "${TMP}/logs/existing.stderr" \
  "${BORIS}" validate --input="${VALID}" --html-layout="${LAYOUT}" \
  --html-dir="${EXISTING_OUT}" --quiet
printf 'foreign sentinel\n' >"${TMP}/expected-sentinel.txt"
cmp "${TMP}/expected-sentinel.txt" "${EXISTING_OUT}/sentinel.txt"
test "$(find "${EXISTING_OUT}" -type f -print | wc -l | tr -d '[:space:]')" = "1"
test ! -e "${EXISTING_OUT}.boris-stage"

# Canonical parser, identity, graph, and semantic-relation diagnostics.
run_invalid_fixture malformed-frontmatter \
  "docs/contracts/fixtures/malformed-frontmatter/content" EFRONTMATTER
run_invalid_fixture invalid-id \
  "docs/contracts/fixtures/invalid-id/content" EINVALIDPATH
run_invalid_fixture missing-parent \
  "docs/contracts/fixtures/missing-parent/content" EPARENTMISSING
run_invalid_fixture semantic-relations \
  "docs/contracts/fixtures/semantic-relations-invalid/content" ERELATIONMISSING
grep -q ERELATIONSELF "${TMP}/logs/semantic-relations.stderr"

# The representative duplicate-id failure is byte-identical to normal compile
# validation, including its source locus and remediation text.
DUPLICATE="docs/contracts/fixtures/duplicate-ids/content"
DUPLICATE_VALIDATE_OUT="${TMP}/duplicate-validate-output"
DUPLICATE_BUILD_OUT="${TMP}/duplicate-build-output"
run_expect 1 "${TMP}/logs/duplicate-validate.stdout" "${TMP}/logs/duplicate-validate.stderr" \
  "${BORIS}" validate --input="${DUPLICATE}" --html-layout="${LAYOUT}" \
  --html-dir="${DUPLICATE_VALIDATE_OUT}"
run_expect 1 "${TMP}/logs/duplicate-build.stdout" "${TMP}/logs/duplicate-build.stderr" \
  "${BORIS}" build --input="${DUPLICATE}" --html-layout="${LAYOUT}" \
  --html-dir="${DUPLICATE_BUILD_OUT}"
grep -q EDUPLICATEID "${TMP}/logs/duplicate-validate.stderr"
cmp "${TMP}/logs/duplicate-validate.stdout" "${TMP}/logs/duplicate-build.stdout"
cmp "${TMP}/logs/duplicate-validate.stderr" "${TMP}/logs/duplicate-build.stderr"
assert_no_target "${DUPLICATE_VALIDATE_OUT}"
assert_no_target "${DUPLICATE_BUILD_OUT}"

# #829: `--report` carries the real structured diagnostic — never a phantom
# EIO fallback and never an inflated errorCount.
FM_CONTENT="${TMP}/report-content"
mkdir -p "${FM_CONTENT}"
printf '%s\n' '---' 'category: unknown' '---' '# Bad' >"${FM_CONTENT}/bad.md"
FM_REPORT="${TMP}/report-frontmatter.json"
run_expect 1 "${TMP}/logs/report-fm.stdout" "${TMP}/logs/report-fm.stderr" \
  "${BORIS}" validate --input="${FM_CONTENT}" --html-layout="${LAYOUT}" \
  --html-dir="${TMP}/report-fm-output" --report="${FM_REPORT}"
grep -q '"code": "EFRONTMATTER"' "${FM_REPORT}"
grep -q '"sourcePath": "bad.md"' "${FM_REPORT}"
grep -q '"line": 2' "${FM_REPORT}"
grep -q '"errorCount": 1' "${FM_REPORT}"
if grep -q '"code": "EIO"' "${FM_REPORT}"; then
  printf 'report contains a phantom EIO fallback alongside EFRONTMATTER\n' >&2
  exit 1
fi
assert_no_target "${TMP}/report-fm-output"

DUP_REPORT="${TMP}/report-duplicate.json"
run_expect 1 "${TMP}/logs/report-dup.stdout" "${TMP}/logs/report-dup.stderr" \
  "${BORIS}" validate --input="${DUPLICATE}" --html-layout="${LAYOUT}" \
  --html-dir="${TMP}/report-dup-output" --report="${DUP_REPORT}"
test "$(grep -o '"code": "EDUPLICATEID"' "${DUP_REPORT}" | wc -l | tr -d '[:space:]')" = "1"
grep -q '"errorCount": 1' "${DUP_REPORT}"
if grep -q '"code": "EIO"' "${DUP_REPORT}" || grep -q GraphValidationFailed "${DUP_REPORT}"; then
  printf 'report duplicates EDUPLICATEID with a phantom EIO: GraphValidationFailed\n' >&2
  exit 1
fi
assert_no_target "${TMP}/report-dup-output"

# A genuine I/O failure (missing content root) keeps the EIO fallback: no
# structured diagnostic exists, so the report must still explain exit 3.
IO_REPORT="${TMP}/report-io.json"
run_expect 3 "${TMP}/logs/report-io.stdout" "${TMP}/logs/report-io.stderr" \
  "${BORIS}" validate --input="${TMP}/no-such-content-root" --html-layout="${LAYOUT}" \
  --html-dir="${TMP}/report-io-output" --report="${IO_REPORT}"
grep -q '"code": "EIO"' "${IO_REPORT}"
grep -q '"errorCount": 1' "${IO_REPORT}"

# #830: Unicode whitespace in a page filename is rejected like ASCII space —
# nothing is published with a raw non-ASCII whitespace id or href.
NBSP_CONTENT="${TMP}/nbsp-content"
mkdir -p "${NBSP_CONTENT}"
printf '# nbsp page\n' >"${NBSP_CONTENT}/with_nbsp_$(printf '\xc2\xa0')x.md"
NBSP_OUT="${TMP}/nbsp-output"
run_expect 3 "${TMP}/logs/nbsp.stdout" "${TMP}/logs/nbsp.stderr" \
  "${BORIS}" validate --input="${NBSP_CONTENT}" --html-layout="${LAYOUT}" \
  --html-dir="${NBSP_OUT}"
grep -q InvalidPath "${TMP}/logs/nbsp.stderr"
assert_no_target "${NBSP_OUT}"

# `id:` frontmatter values with Unicode whitespace are rejected as invalid
# canonical entity ids (EINVALIDPATH), mirroring the ASCII-space rule.
NBSP_ID_CONTENT="${TMP}/nbsp-id-content"
mkdir -p "${NBSP_ID_CONTENT}"
printf '%s\n' '---' "id: bad$(printf '\xc2\xa0')id" 'title: Bad id' '---' '# Body' >"${NBSP_ID_CONTENT}/index.md"
run_expect 1 "${TMP}/logs/nbsp-id.stdout" "${TMP}/logs/nbsp-id.stderr" \
  "${BORIS}" validate --input="${NBSP_ID_CONTENT}" --html-layout="${LAYOUT}" \
  --html-dir="${TMP}/nbsp-id-output"
grep -q EINVALIDPATH "${TMP}/logs/nbsp-id.stderr"
assert_no_target "${TMP}/nbsp-id-output"

# Includes, wiki links/fragments, and registered-component checks travel
# through the normal dependency and renderer implementations.
INCLUDE_CONTENT="${TMP}/include-content"
mkdir -p "${INCLUDE_CONTENT}"
printf '%s\n' '---' 'title: Missing include' '---' \
  '{{include includes/does-not-exist.md}}' >"${INCLUDE_CONTENT}/index.md"
run_invalid_fixture missing-include "${INCLUDE_CONTENT}" EINCLUDEMISSING
run_invalid_fixture missing-wiki-fragment \
  "docs/contracts/fixtures/wiki-heading-missing/content" EREFERENCEMISSING
run_invalid_fixture bad-component \
  "test/fixtures/component-fail/content" ECOMPONENT

ASSET_CONTENT="${TMP}/asset-content"
mkdir -p "${ASSET_CONTENT}/index.assets"
printf '%s\n' '---' 'title: Unsafe asset' '---' \
  '![logo](index.assets/logo.svg)' >"${ASSET_CONTENT}/index.md"
printf '%s\n' '<svg><script>alert(1)</script></svg>' \
  >"${ASSET_CONTENT}/index.assets/logo.svg"
run_invalid_fixture unsafe-content-asset "${ASSET_CONTENT}" EASSET

# Layout and target isolation are applicable selected-target configuration.
LAYOUT_OUT="${TMP}/layout-output"
run_expect 1 "${TMP}/logs/layout.stdout" "${TMP}/logs/layout.stderr" \
  "${BORIS}" validate --input="${VALID}" \
  --html-layout="test/fixtures/layouts/missing-marker.html" --html-dir="${LAYOUT_OUT}"
grep -q LayoutMissingMarker "${TMP}/logs/layout.stderr"
assert_no_target "${LAYOUT_OUT}"

COLLISION_OUT="${TMP}/collision-output"
run_expect 2 "${TMP}/logs/target.stdout" "${TMP}/logs/target.stderr" \
  "${BORIS}" validate --input="${VALID}" --html-layout="${LAYOUT}" \
  --target="first=${COLLISION_OUT}" --target="second=${COLLISION_OUT}"
grep -q TargetOutputCollision "${TMP}/logs/target.stderr"
assert_no_target "${COLLISION_OUT}"

# A source accepted by validation remains publishable through the normal HTML
# path; publication artifacts appear only after this explicit build.
BUILD_OUT="${TMP}/normal-build-output"
run_expect 0 "${TMP}/logs/build.stdout" "${TMP}/logs/build.stderr" \
  "${BORIS}" build --input="${VALID}" --html-layout="${LAYOUT}" \
  --html-dir="${BUILD_OUT}" --sitemap --site-url="https://example.test/docs/" --quiet
test -f "${BUILD_OUT}/index.html"
test -f "${BUILD_OUT}/sitemap.xml"
test -f "${BUILD_OUT}/_boris/search/search-index.json"
test -f "${BUILD_OUT}/_boris/proof/artifacts.json"

printf 'Validation contract process tests: PASS\n'
