#!/usr/bin/env bash
# Boris release gate — mechanical checks for reviewers and CI.
# See docs/RELEASE-GATE.md.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

GATE_DIR=".release-gate"
VALID_CONTENT="docs/contracts/fixtures/valid/content"
VALID_EXPECTED="docs/contracts/fixtures/valid/expected"
IR_OUT="${GATE_DIR}/ir-valid"
RAG_A="${GATE_DIR}/rag-a"
RAG_B="${GATE_DIR}/rag-b"
RAG_COMPLETE="${GATE_DIR}/rag-complete"
FAIL=0

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*"; FAIL=1; }

cleanup() {
  rm -rf "${GATE_DIR}"
}
trap cleanup EXIT

note "0. Preconditions"
command -v zig >/dev/null || { echo "zig not on PATH"; exit 1; }
ZIG_VER="$(zig version | tr -d '\r')"
ZON_MIN="$(sed -n 's/.*minimum_zig_version *= *"\([^"]*\)".*/\1/p' build.zig.zon | head -1)"
PRODUCT_VERSION="$(sed -n 's/.*\.version *= *"\([^"]*\)".*/\1/p' build.zig.zon | head -1)"
CI_ZIG="$(sed -n 's/.*version: *\([0-9][0-9.]*\).*/\1/p' .github/workflows/ci.yml | head -1)"
pass "zig version: ${ZIG_VER}"
pass "build.zig.zon minimum_zig_version: ${ZON_MIN}"
pass "build.zig.zon product version: ${PRODUCT_VERSION}"
pass "CI pin: ${CI_ZIG}"

# --- 8. Zig version alignment (document + package + CI) -----------------
note "8. Zig version alignment"
if [[ -z "${ZON_MIN}" || -z "${CI_ZIG}" ]]; then
  fail "could not parse Zig versions from build.zig.zon / CI"
elif [[ "${ZON_MIN}" != "${CI_ZIG}" ]]; then
  fail "build.zig.zon (${ZON_MIN}) != CI (${CI_ZIG})"
else
  pass "package and CI both ${ZON_MIN}"
fi
# Host zig must be compatible (same major.minor as pin; patch may differ)
ZON_MM="${ZON_MIN%.*}"
HOST_MM="$(echo "${ZIG_VER}" | awk -F. '{print $1"."$2}')"
if [[ "${HOST_MM}" != "${ZON_MM}" ]]; then
  fail "host Zig ${ZIG_VER} major.minor != package ${ZON_MIN}"
else
  pass "host Zig ${ZIG_VER} matches package major.minor ${ZON_MM}"
fi
if ! grep -q "${ZON_MIN}" README.md; then
  # README says 0.16+ ; require the minor family
  if ! grep -qE '0\.16' README.md; then
    fail "README.md does not mention Zig 0.16"
  else
    pass "README.md documents Zig 0.16 family"
  fi
else
  pass "README.md mentions ${ZON_MIN}"
fi
if ! grep -qE '0\.16' docs/STATUS.md; then
  fail "docs/STATUS.md does not mention Zig 0.16"
else
  pass "docs/STATUS.md documents Zig 0.16 family"
fi

# --- 1. Build ------------------------------------------------------------
note "1. zig build"
zig build
pass "build succeeded"
BORIS="zig-out/bin/boris"
[[ -x "${BORIS}" ]] || fail "missing ${BORIS}"

# --- 2. Tests ------------------------------------------------------------
note "2. zig build test"
zig build test
pass "test suite succeeded"

# --- 2a. CLI process contract ---------------------------------------------
note "2a. CLI process contract"
if test/cli-contract.sh "${BORIS}"; then
  pass "CLI process contract succeeded"
else
  fail "CLI process contract failed"
fi

# --- 2b. Authoritative no-publication validation --------------------------
note "2b. authoritative no-publication validation"
if test/validate-contract.sh "${BORIS}"; then
  pass "validation contract succeeded"
else
  fail "validation contract failed"
fi

# --- 3. RAG dual export determinism --------------------------------------
note "3. RAG generation twice + byte-for-byte comparison"
rm -rf "${RAG_A}" "${RAG_B}"
# Prefer live demo content when it parses under product parent-only grammar.
# Fall back to the valid contract fixture if demo content fails.
RAG_INPUT="${VALID_CONTENT}"
if [[ -d content ]]; then
  if "${BORIS}" --rag --rag-dir="${RAG_A}" --input=content --quiet 2>/dev/null; then
    RAG_INPUT="content"
    rm -rf "${RAG_A}"
  else
    rm -rf "${RAG_A}"
  fi
fi
"${BORIS}" --rag --rag-dir="${RAG_A}" --input="${RAG_INPUT}" --quiet
"${BORIS}" --rag --rag-dir="${RAG_B}" --input="${RAG_INPUT}" --quiet
if diff -rq "${RAG_A}" "${RAG_B}" >/dev/null; then
  pass "dual RAG trees byte-identical (input=${RAG_INPUT})"
else
  fail "RAG trees differ"
  diff -rq "${RAG_A}" "${RAG_B}" || true
fi

# --- 6. catalog_meta.json + catalog.jsonl schema -------------------------
note "6. catalog_meta.json, catalog.jsonl, and working-pack checks"
# Working mode: bounded upload files + manifest sidecar only — no
# catalog_meta.json, no system seeds, no hashes in pack envelopes.
if compgen -G "${RAG_A}/working-*.md" >/dev/null; then
  pass "working pack files present"
else
  fail "missing working-*.md packs"
fi
if [[ -f "${RAG_A}/manifest.json" ]] && grep -q '"mode":"working"' "${RAG_A}/manifest.json" && grep -q '"sidecar_files"' "${RAG_A}/manifest.json"; then
  pass "manifest.json sidecar present with mode + sidecar_files"
else
  fail "manifest.json sidecar missing or malformed"
fi
if [[ -f "${RAG_A}/catalog_meta.json" ]]; then
  fail "working mode must not emit catalog_meta.json (manifest.json records format/schema/version)"
else
  pass "working mode emits no catalog_meta.json"
fi
if [[ -d "${RAG_A}/system" ]] || compgen -G "${RAG_A}/system/**" >/dev/null 2>&1; then
  fail "working mode must not seed system/** documents"
else
  pass "working mode contains no system seeds"
fi
# Document bodies are verbatim and may legitimately discuss hashes in prose;
# the contract violation would be an integrity record inside an envelope.
if grep -rE 'boris-rag-doc:.*(sha256|hash|bytes)' "${RAG_A}"/working-*.md; then
  fail "working pack envelopes must not carry integrity fields (sidecar only)"
else
  pass "working pack envelopes carry no per-document integrity fields"
fi
# Complete-corpus tree carries catalog.jsonl + catalog_meta.json.
rm -rf "${RAG_COMPLETE}"
"${BORIS}" --rag --complete --rag-dir="${RAG_COMPLETE}" --input="${RAG_INPUT}" --quiet
META="${RAG_COMPLETE}/catalog_meta.json"
if [[ ! -f "${META}" ]]; then
  fail "missing catalog_meta.json (complete corpus)"
else
  # Fixed compact shape (schema v2)
  EXPECT_META="{\"format\":\"boris-rag\",\"schema_version\":2,\"boris_version\":\"${PRODUCT_VERSION}\"}"
  GOT_META="$(tr -d '\n' < "${META}" | sed 's/[[:space:]]//g')"
  # Allow trailing newline already stripped; tolerate pretty vs compact by
  # requiring keys and values rather than exact whitespace.
  if [[ "${GOT_META}" == "${EXPECT_META}" ]]; then
    pass "catalog_meta.json fields (format/schema_version/boris_version)"
  else
    fail "catalog_meta.json shape mismatch: $(cat "${META}")"
  fi
  # Prefer exact compact form when present
  if [[ "${GOT_META}" == "${EXPECT_META}" ]]; then
    pass "catalog_meta.json exact compact form"
  fi
fi
# Complete mode rejects --scope: complete means the entire validated corpus.
set +e
COMPLETE_SCOPE_ERR="$("${BORIS}" --rag --complete --scope=home --rag-dir="${GATE_DIR}/rag-complete-scope" --input="${RAG_INPUT}" 2>&1)"
COMPLETE_SCOPE_EC=$?
set -e
if [[ "${COMPLETE_SCOPE_EC}" -eq 2 ]] && [[ ! -d "${GATE_DIR}/rag-complete-scope" ]]; then
  pass "--complete with --scope is a usage error (exit 2, no export)"
else
  fail "--complete with --scope expected exit 2 with no export (got ${COMPLETE_SCOPE_EC})"
fi
JSONL="${RAG_COMPLETE}/catalog.jsonl"
if [[ ! -f "${JSONL}" ]]; then
  fail "missing catalog.jsonl (complete corpus)"
else
  # First object keys must start with pinned order
  FIRST="$(head -1 "${JSONL}")"
  if [[ "${FIRST}" == '{"rag_id":'* ]]; then
    for key in rag_id rag_path category title entity_id role parent_entry tags; do
      if ! grep -q "\"${key}\"" <<<"${FIRST}"; then
        fail "catalog.jsonl first line missing key ${key}"
      fi
    done
    # Key order: positions must increase
    prev=-1
    order_ok=1
    for key in rag_id rag_path category title entity_id role parent_entry tags; do
      pos="$(awk -v k="\"${key}\"" 'BEGIN{print index(ARGV[1],k)}' "${FIRST}")"
      if [[ -z "${pos}" || "${pos}" -eq 0 || "${pos}" -le "${prev}" ]]; then
        order_ok=0
        break
      fi
      prev="${pos}"
    done
    if [[ "${order_ok}" -eq 1 ]]; then
      pass "catalog.jsonl pinned key order on first line"
    else
      fail "catalog.jsonl key order wrong: ${FIRST}"
    fi
  else
    fail "catalog.jsonl first line does not start with rag_id object"
  fi
  # Machine sidecars must not appear as catalog rows
  if grep -q '"rag_path":"catalog.jsonl"' "${JSONL}" \
    || grep -q '"rag_path":"catalog_meta.json"' "${JSONL}"; then
    fail "catalog.jsonl must not list machine sidecar files as rows"
  else
    pass "catalog.jsonl excludes machine sidecars"
  fi
fi

# --- 4. Valid fixture IR goldens (+ report structure) --------------------
note "4. Valid fixture produces expected IR artifacts"
rm -rf "${IR_OUT}"
"${BORIS}" --input="${VALID_CONTENT}" --out="${IR_OUT}" --quiet
for f in manifest.json graph.json completion.json build-report.json; do
  [[ -f "${IR_OUT}/${f}" ]] || fail "missing ${f}"
done
if diff -u "${VALID_EXPECTED}/manifest.json" "${IR_OUT}/manifest.json"; then
  pass "manifest.json matches golden"
else
  fail "manifest.json golden mismatch"
fi
if diff -u "${VALID_EXPECTED}/graph.json" "${IR_OUT}/graph.json"; then
  pass "graph.json matches golden"
else
  fail "graph.json golden mismatch"
fi
if diff -u "${VALID_EXPECTED}/completion.json" "${IR_OUT}/completion.json"; then
  pass "completion.json matches golden"
else
  fail "completion.json golden mismatch"
fi
if diff -u "${VALID_EXPECTED}/build-report.json" "${IR_OUT}/build-report.json"; then
  pass "build-report.json matches golden"
else
  fail "build-report.json golden mismatch"
fi

note "4a. Graph-native dependency IR golden"
GRAPH_NATIVE_CONTENT="docs/contracts/fixtures/graph-native-dependencies/content"
GRAPH_NATIVE_EXPECTED="docs/contracts/fixtures/graph-native-dependencies/expected/graph.json"
GRAPH_NATIVE_OUT="${GATE_DIR}/ir-graph-native"
rm -rf "${GRAPH_NATIVE_OUT}"
"${BORIS}" --input="${GRAPH_NATIVE_CONTENT}" --out="${GRAPH_NATIVE_OUT}" --quiet
if diff -u "${GRAPH_NATIVE_EXPECTED}" "${GRAPH_NATIVE_OUT}/graph.json"; then
  pass "graph-native graph.json matches typed-edge + reverseIndex golden"
else
  fail "graph-native graph.json golden mismatch"
fi

note "4a. Semantic relations IR 0.3 fixture"
SEMANTIC_CONTENT="docs/contracts/fixtures/semantic-relations/content"
SEMANTIC_OUT="${GATE_DIR}/ir-semantic-relations"
rm -rf "${SEMANTIC_OUT}"
"${BORIS}" --input="${SEMANTIC_CONTENT}" --out="${SEMANTIC_OUT}" --quiet
if grep -q '"schemaVersion": "0.3.0"' "${SEMANTIC_OUT}/manifest.json" \
  && grep -q '"schemaVersion": "0.3.0"' "${SEMANTIC_OUT}/graph.json" \
  && grep -q '"schemaVersion": "0.3.0"' "${SEMANTIC_OUT}/build-report.json"; then
  pass "semantic relation artifacts advertise IR 0.3"
else
  fail "semantic relation artifacts must advertise IR 0.3"
fi
if grep -q '"kind": "depends_on"' "${SEMANTIC_OUT}/graph.json" \
  && grep -q '"kind": "supersedes"' "${SEMANTIC_OUT}/graph.json"; then
  pass "semantic relation graph emits bounded relation kinds"
else
  fail "semantic relation graph missing expected relation kinds"
fi
if diff -u "docs/contracts/fixtures/semantic-relations/expected/relations.json" \
  <(sed -n '/^  "relations":/,$p' "${SEMANTIC_OUT}/graph.json"); then
  pass "semantic relation ordering and shape match golden"
else
  fail "semantic relation ordering or shape mismatch"
fi
SEMANTIC_INVALID_OUT="${GATE_DIR}/ir-semantic-relations-invalid"
rm -rf "${SEMANTIC_INVALID_OUT}"
set +e
"${BORIS}" --input="docs/contracts/fixtures/semantic-relations-invalid/content" --out="${SEMANTIC_INVALID_OUT}" --quiet
semantic_invalid_rc=$?
set -e
if [[ "${semantic_invalid_rc}" -eq 1 ]] \
  && grep -q '"code": "ERELATIONSELF"' "${SEMANTIC_INVALID_OUT}/build-report.json" \
  && grep -q '"code": "ERELATIONMISSING"' "${SEMANTIC_INVALID_OUT}/build-report.json"; then
  pass "semantic relation self and missing targets fail closed"
else
  fail "semantic relation invalid-target diagnostics mismatch"
fi

note "4a. AI Context Bundle determinism and provenance"
CONTEXT_A="${GATE_DIR}/context-a"
CONTEXT_B="${GATE_DIR}/context-b"
rm -rf "${CONTEXT_A}" "${CONTEXT_B}"
"${BORIS}" --context --context-dir="${CONTEXT_A}" --input="${SEMANTIC_CONTENT}" --quiet
"${BORIS}" --context --context-dir="${CONTEXT_B}" --input="${SEMANTIC_CONTENT}" --quiet
if diff -rq "${CONTEXT_A}" "${CONTEXT_B}" >/dev/null; then
  pass "context bundles are byte-identical across repeated exports"
else
  fail "context bundle exports differ"
fi
if [[ -f "${CONTEXT_A}/bundle.md" && -f "${CONTEXT_A}/graph.json" \
  && -f "${CONTEXT_A}/manifest.json" \
  && -f "${CONTEXT_A}/pages/guides/cache-v2.md" ]] \
  && grep -q '"format": "boris-context"' "${CONTEXT_A}/manifest.json" \
  && grep -q 'source_sha256' "${CONTEXT_A}/pages/guides/cache-v2.md" \
  && grep -q '^````markdown$' "${CONTEXT_A}/pages/guides/cache-v2.md" \
  && grep -q '"relation_count": 5' "${CONTEXT_A}/manifest.json"; then
  pass "context bundle has manifest, graph, page provenance, and relation count"
else
  fail "context bundle provenance artifacts missing"
fi
context_hashes_ok=1
while read -r context_artifact context_expected_hash; do
  [[ -n "${context_artifact}" ]] || continue
  context_artifact_path="${CONTEXT_A}/${context_artifact}"
  if [[ ! -f "${context_artifact_path}" ]]; then
    context_hashes_ok=0
    fail "context manifest references missing artifact ${context_artifact}"
    continue
  fi
  context_actual_hash="$(shasum -a 256 "${context_artifact_path}" | awk '{print $1}')"
  if [[ "${context_actual_hash}" != "${context_expected_hash}" ]]; then
    context_hashes_ok=0
    fail "context artifact digest mismatch: ${context_artifact}"
  fi
done < <(sed -n 's/.*{"path":"\([^"]*\)","sha256":"\([^"]*\)"}.*/\1 \2/p' "${CONTEXT_A}/manifest.json")
if [[ "${context_hashes_ok}" -eq 1 ]]; then
  pass "context manifest digests match every published artifact"
fi
CONTEXT_BEFORE_INVALID="${GATE_DIR}/context-before-invalid"
rm -rf "${CONTEXT_BEFORE_INVALID}"
cp -R "${CONTEXT_A}" "${CONTEXT_BEFORE_INVALID}"
context_before="$(shasum -a 256 "${CONTEXT_A}/manifest.json")"
set +e
"${BORIS}" --context --context-dir="${CONTEXT_A}" --input="docs/contracts/fixtures/semantic-relations-invalid/content" --quiet
context_invalid_rc=$?
set -e
context_after="$(shasum -a 256 "${CONTEXT_A}/manifest.json")"
if [[ "${context_invalid_rc}" -eq 1 && "${context_before}" == "${context_after}" ]] \
  && diff -rq "${CONTEXT_A}" "${CONTEXT_BEFORE_INVALID}" >/dev/null; then
  pass "invalid context input leaves the prior bundle tree untouched"
else
  fail "invalid context input replaced or damaged the prior bundle tree"
fi
# Feature 2: bare-style default HTML (relative html-dir under gate dir)
note "4b. Default HTML surface (Feature 2)"
HTML_OUT="${GATE_DIR}/html-default"
rm -rf "${HTML_OUT}"
"${BORIS}" --input=test/fixtures/html/content --html-dir="${HTML_OUT}" --quiet
if [[ -f "${HTML_OUT}/index.html" ]]; then
  pass "HTML default path wrote index.html under ${HTML_OUT}"
else
  fail "HTML default path missing index.html"
fi
# IR remains opt-in via --out (already exercised above)
pass "IR: explicit --out path remains contract surface"
# RAG artifacts already produced in steps 3/6
pass "RAG: working packs + manifest sidecar (step 3) and complete-corpus catalog (step 6)"

# --- 4c. Feature 9 heading-fragment wiki (HTML) --------------------------
note "4c. Feature 9 heading-fragment wiki links (HTML)"
F9_OK_CONTENT="docs/contracts/fixtures/wiki-heading-fragments/content"
F9_BAD_CONTENT="docs/contracts/fixtures/wiki-heading-missing/content"
# Layout must not sit beside the HTML out dir (target path-boundary rules).
F9_LAYOUT="test/fixtures/html/layouts/main.html"
F9_OK_OUT="${GATE_DIR}/html-f9-ok"
F9_BAD_OUT="${GATE_DIR}/html-f9-bad"
rm -rf "${F9_OK_OUT}" "${F9_BAD_OUT}"
if "${BORIS}" --input="${F9_OK_CONTENT}" --html-layout="${F9_LAYOUT}" --html-dir="${F9_OK_OUT}" --quiet; then
  if grep -q 'href="guides/target.html#section-one"' "${F9_OK_OUT}/index.html" \
    && grep -q 'href="../index.html#home"' "${F9_OK_OUT}/guides/from.html"; then
    pass "F9 success fixture: fragment hrefs present (trunk + satellite)"
  else
    fail "F9 success fixture: missing expected fragment hrefs"
    head -20 "${F9_OK_OUT}/index.html" || true
  fi
else
  fail "F9 success fixture: compile failed"
fi
set +e
F9_ERR="$("${BORIS}" --input="${F9_BAD_CONTENT}" --html-layout="${F9_LAYOUT}" --html-dir="${F9_BAD_OUT}" 2>&1)"
F9_EC=$?
set -e
if [[ "${F9_EC}" -ne 1 ]]; then
  fail "F9 missing-heading: expected exit 1, got ${F9_EC}"
else
  pass "F9 missing-heading: exit 1"
fi
if grep -q 'EREFERENCEMISSING' <<<"${F9_ERR}" && grep -q 'does-not-exist' <<<"${F9_ERR}"; then
  pass "F9 missing-heading: EREFERENCEMISSING for fragment"
else
  fail "F9 missing-heading: diagnostic mismatch"
  printf '%s\n' "${F9_ERR}" | head -20
fi

# --- 4c2. Layout selection (--layout-rule) --------------------------------
note "4c2. Layout selection (--layout-rule)"
LR_ROOT="docs/contracts/fixtures/layout-rules"
LR_CONTENT="${LR_ROOT}/content"
LR_THEME="${LR_ROOT}/theme"
LR_OUT_A="${GATE_DIR}/layout-rules-a"
LR_OUT_B="${GATE_DIR}/layout-rules-b"
LR_OUT_INC="${GATE_DIR}/layout-rules-inc"
rm -rf "${LR_OUT_A}" "${LR_OUT_B}" "${LR_OUT_INC}"

# Order A
if "${BORIS}" --input="${LR_CONTENT}" --theme="${LR_THEME}" \
  --layout-rule default id:index "${LR_THEME}/layouts/home.html" \
  --layout-rule default 'glob:reference/*' "${LR_THEME}/layouts/reference.html" \
  --layout-rule default role:trunk "${LR_THEME}/layouts/section.html" \
  --html-dir="${LR_OUT_A}" --quiet; then
  if grep -q 'data-layout="home"' "${LR_OUT_A}/index.html" \
    && grep -q 'data-layout="section"' "${LR_OUT_A}/guides.html" \
    && grep -q 'data-layout="main"' "${LR_OUT_A}/guides/getting-started.html" \
    && grep -q 'data-layout="section"' "${LR_OUT_A}/reference.html" \
    && grep -q 'data-layout="reference"' "${LR_OUT_A}/reference/configuration.html"; then
    pass "layout-rules: exact/glob/role/fallback markers"
  else
    fail "layout-rules: missing expected data-layout markers"
    head -5 "${LR_OUT_A}/index.html" || true
  fi
else
  fail "layout-rules: compile failed"
fi

# Order B (permuted rules) — byte-identical page HTML
if "${BORIS}" --input="${LR_CONTENT}" --theme="${LR_THEME}" \
  --layout-rule default role:trunk "${LR_THEME}/layouts/section.html" \
  --layout-rule default 'glob:reference/*' "${LR_THEME}/layouts/reference.html" \
  --layout-rule default id:index "${LR_THEME}/layouts/home.html" \
  --html-dir="${LR_OUT_B}" --quiet; then
  if diff -rq "${LR_OUT_A}" "${LR_OUT_B}" >/dev/null; then
    pass "layout-rules: rule order permutation byte-identical"
  else
    fail "layout-rules: rule order permutation produced different trees"
    diff -rq "${LR_OUT_A}" "${LR_OUT_B}" || true
  fi
else
  fail "layout-rules: permuted compile failed"
fi

# Incremental cold then no-op
if "${BORIS}" --input="${LR_CONTENT}" --theme="${LR_THEME}" \
  --layout-rule default id:index "${LR_THEME}/layouts/home.html" \
  --layout-rule default 'glob:reference/*' "${LR_THEME}/layouts/reference.html" \
  --layout-rule default role:trunk "${LR_THEME}/layouts/section.html" \
  --html-dir="${LR_OUT_INC}" --incremental --quiet \
  && "${BORIS}" --input="${LR_CONTENT}" --theme="${LR_THEME}" \
  --layout-rule default id:index "${LR_THEME}/layouts/home.html" \
  --layout-rule default 'glob:reference/*' "${LR_THEME}/layouts/reference.html" \
  --layout-rule default role:trunk "${LR_THEME}/layouts/section.html" \
  --html-dir="${LR_OUT_INC}" --incremental --quiet; then
  if [[ -f "${LR_OUT_INC}/.boris-cache/manifest.json" ]] \
    && grep -q 'boris-cache-v3-nav-digest' "${LR_OUT_INC}/.boris-cache/manifest.json" \
    && grep -q 'selected_layout' "${LR_OUT_INC}/.boris-cache/manifest.json"; then
    pass "layout-rules: incremental cache v2 + selected_layout"
  else
    fail "layout-rules: cache manifest missing v2/selected_layout"
  fi
else
  fail "layout-rules: incremental compile failed"
fi

# Ambiguous equal-specificity globs → exit 2
set +e
LR_AMB_OUT="${GATE_DIR}/layout-rules-amb"
rm -rf "${LR_AMB_OUT}"
LR_AMB_ERR="$("${BORIS}" --input="${LR_CONTENT}" --theme="${LR_THEME}" \
  --layout-rule default 'glob:reference/*' "${LR_THEME}/layouts/reference.html" \
  --layout-rule default 'glob:*/configuration' "${LR_THEME}/layouts/main.html" \
  --html-dir="${LR_AMB_OUT}" 2>&1)"
LR_AMB_EC=$?
set -e
if [[ "${LR_AMB_EC}" -eq 2 ]]; then
  pass "layout-rules: ambiguous globs exit 2"
else
  fail "layout-rules: ambiguous globs expected exit 2, got ${LR_AMB_EC}"
  printf '%s\n' "${LR_AMB_ERR}" | head -10
fi
if [[ -d "${LR_AMB_OUT}" ]] && find "${LR_AMB_OUT}" -name '*.html' 2>/dev/null | grep -q .; then
  fail "layout-rules: ambiguous globs published HTML"
else
  pass "layout-rules: ambiguous globs did not publish HTML"
fi

# layout: frontmatter → exit 1 EFRONTMATTER (IR path prints the diagnostic code)
set +e
LR_FM_OUT="${GATE_DIR}/layout-rules-fm-ir"
rm -rf "${LR_FM_OUT}"
LR_FM_ERR="$("${BORIS}" --input="${LR_ROOT}/adversarial/frontmatter-layout/content" \
  --out="${LR_FM_OUT}" 2>&1)"
LR_FM_EC=$?
set -e
if [[ "${LR_FM_EC}" -eq 1 ]] && grep -q 'EFRONTMATTER' <<<"${LR_FM_ERR}"; then
  pass "layout-rules: layout frontmatter is EFRONTMATTER"
else
  fail "layout-rules: layout frontmatter expected exit 1 EFRONTMATTER, got ${LR_FM_EC}"
  printf '%s\n' "${LR_FM_ERR}" | head -10
fi

# --layout-rule with IR → exit 2
set +e
"${BORIS}" --layout-rule default id:index layouts/main.html --out "${GATE_DIR}/layout-rules-ir" --quiet >/dev/null 2>&1
LR_IR_EC=$?
set -e
if [[ "${LR_IR_EC}" -eq 2 ]]; then
  pass "layout-rules: conflicts with IR (--out)"
else
  fail "layout-rules: expected exit 2 with --out, got ${LR_IR_EC}"
fi

# Mixed managed theme roots → exit 2
set +e
LR_MIX_OUT="${GATE_DIR}/layout-rules-mix"
rm -rf "${LR_MIX_OUT}"
LR_MIX_ERR="$("${BORIS}" --input="${LR_ROOT}/adversarial/mixed-theme/content" \
  --theme="${LR_THEME}" \
  --layout-rule default id:index layouts/main.html \
  --html-dir="${LR_MIX_OUT}" 2>&1)"
LR_MIX_EC=$?
set -e
if [[ "${LR_MIX_EC}" -eq 2 ]]; then
  pass "layout-rules: mixed theme roots exit 2"
else
  fail "layout-rules: mixed theme roots expected exit 2, got ${LR_MIX_EC}"
  printf '%s\n' "${LR_MIX_ERR}" | head -10
fi

# Layout path with .. / absolute → exit 2 (lexical gate; no publish)
set +e
LR_TRAV_OUT="${GATE_DIR}/layout-rules-trav"
rm -rf "${LR_TRAV_OUT}"
"${BORIS}" --input="${LR_CONTENT}" --theme="${LR_THEME}" \
  --layout-rule default id:index "${LR_THEME}/layouts/../../layouts/main.html" \
  --html-dir="${LR_TRAV_OUT}" --quiet >/dev/null 2>&1
LR_TRAV_EC=$?
set -e
if [[ "${LR_TRAV_EC}" -eq 2 ]]; then
  pass "layout-rules: traversal layout path exit 2"
else
  fail "layout-rules: traversal layout path expected exit 2, got ${LR_TRAV_EC}"
fi
set +e
"${BORIS}" --input="${LR_CONTENT}" --html-layout '../layouts/main.html' \
  --html-dir="${LR_TRAV_OUT}" --quiet >/dev/null 2>&1
LR_TRAV2_EC=$?
set -e
if [[ "${LR_TRAV2_EC}" -eq 2 ]]; then
  pass "layout-rules: absolute/.. html-layout exit 2"
else
  fail "layout-rules: .. html-layout expected exit 2, got ${LR_TRAV2_EC}"
fi

# --- 4d. Documentation Intelligence reports + no-artifact behavior --------
note "4d. Documentation Intelligence reports"
DI_CONTENT="docs/contracts/fixtures/documentation-intelligence/content"
DI_EXPECTED="docs/contracts/fixtures/documentation-intelligence/expected"
DI_PROBE="${GATE_DIR}/di-probe"
mkdir -p "${DI_PROBE}"
DI_CHECK_JSON="${DI_PROBE}/di-check.json"
DI_IMPACT_JSON="${DI_PROBE}/di-impact.json"
DI_CHECK_HUMAN="${DI_PROBE}/di-check.txt"
DI_IMPACT_HUMAN="${DI_PROBE}/di-impact.txt"
set +e
"${BORIS}" check --input="${DI_CONTENT}" --format=json --report="${DI_CHECK_JSON}" --quiet
DI_CHECK_EC=$?
set -e
if [[ "${DI_CHECK_EC}" -eq 0 ]] && diff -u "${DI_EXPECTED}/check.json" "${DI_CHECK_JSON}" >/dev/null; then
  pass "check JSON golden + informational finding exit 0"
else
  fail "check JSON golden or exit code mismatch (got ${DI_CHECK_EC})"
fi
DI_STRICT_CHECK_JSON="${DI_PROBE}/di-check-strict.json"
set +e
"${BORIS}" check --input="${DI_CONTENT}" --format=json --report="${DI_STRICT_CHECK_JSON}" --fail-on-unreferenced --quiet
DI_STRICT_CHECK_JSON_EC=$?
set -e
if [[ "${DI_STRICT_CHECK_JSON_EC}" -eq 1 ]] && diff -u "${DI_CHECK_JSON}" "${DI_STRICT_CHECK_JSON}" >/dev/null; then
  pass "check JSON strict unreferenced policy returns exit 1 with identical report"
else
  fail "check JSON strict unreferenced policy mismatch (got ${DI_STRICT_CHECK_JSON_EC})"
fi

# Explicit command spellings are part of the public CLI contract.  Keep the
# watch smoke non-blocking by exercising its help route; a live watch session
# is covered by the dedicated watch-mode contract and tests.
CLI_CONTRACT_IR="${DI_PROBE}/explicit-build-ir"
if "${BORIS}" build --input="${DI_CONTENT}" --out="${CLI_CONTRACT_IR}" --quiet \
  && [[ -f "${CLI_CONTRACT_IR}/manifest.json" ]] \
  && [[ -f "${CLI_CONTRACT_IR}/graph.json" ]] \
  && [[ -f "${CLI_CONTRACT_IR}/build-report.json" ]] \
  && "${BORIS}" watch --help >/dev/null 2>&1; then
  pass "explicit build/watch command routing"
else
  fail "explicit build/watch command routing"
fi
if "${BORIS}" impact guides/reference --input="${DI_CONTENT}" --format=json --report="${DI_IMPACT_JSON}" --quiet \
  && diff -u "${DI_EXPECTED}/impact.json" "${DI_IMPACT_JSON}" >/dev/null; then
  pass "impact JSON golden + exit 0"
else
  fail "impact JSON golden or exit code mismatch"
fi
set +e
"${BORIS}" check --input="${DI_CONTENT}" --format=human --report="${DI_CHECK_HUMAN}" --quiet
DI_HUMAN_EC=$?
set -e
if [[ "${DI_HUMAN_EC}" -eq 0 ]] && diff -u "${DI_EXPECTED}/check.txt" "${DI_CHECK_HUMAN}" >/dev/null; then
  pass "check human golden"
else
  fail "check human golden or exit code mismatch (got ${DI_HUMAN_EC})"
fi
DI_STRICT_CHECK_HUMAN="${DI_PROBE}/di-check-strict.txt"
set +e
"${BORIS}" check --input="${DI_CONTENT}" --format=human --report="${DI_STRICT_CHECK_HUMAN}" --fail-on-unreferenced --quiet
DI_STRICT_HUMAN_EC=$?
set -e
if [[ "${DI_STRICT_HUMAN_EC}" -eq 1 ]] && diff -u "${DI_CHECK_HUMAN}" "${DI_STRICT_CHECK_HUMAN}" >/dev/null; then
  pass "check strict unreferenced policy returns exit 1 with identical report"
else
  fail "check strict unreferenced policy mismatch (got ${DI_STRICT_HUMAN_EC})"
fi
if "${BORIS}" impact guides/reference --input="${DI_CONTENT}" --format=human --report="${DI_IMPACT_HUMAN}" --quiet \
  && diff -u "${DI_EXPECTED}/impact.txt" "${DI_IMPACT_HUMAN}" >/dev/null; then
  pass "impact human golden"
else
  fail "impact human golden or exit code mismatch"
fi
DI_SOURCE_JSON="${DI_PROBE}/di-impact-source.json"
DI_SOURCE_HUMAN="${DI_PROBE}/di-impact-source.txt"
if "${BORIS}" impact includes/shared.md --input="${DI_CONTENT}" --format=json --report="${DI_SOURCE_JSON}" --quiet \
  && diff -u "${DI_EXPECTED}/impact-source.json" "${DI_SOURCE_JSON}" >/dev/null; then
  pass "source impact JSON golden + exit 0"
else
  fail "source impact JSON golden or exit code mismatch"
fi
if "${BORIS}" impact includes/shared.md --input="${DI_CONTENT}" --format=human --report="${DI_SOURCE_HUMAN}" --quiet \
  && diff -u "${DI_EXPECTED}/impact-source.txt" "${DI_SOURCE_HUMAN}" >/dev/null; then
  pass "source impact human golden"
else
  fail "source impact human golden or exit code mismatch"
fi
DI_MISSING_REPORT="${DI_PROBE}/missing-target.json"
set +e
"${BORIS}" impact does/not-exist --input="${DI_CONTENT}" --format=json --report="${DI_MISSING_REPORT}" --quiet
DI_MISSING_EC=$?
set -e
if [[ "${DI_MISSING_EC}" -eq 2 && ! -e "${DI_MISSING_REPORT}" ]]; then
  pass "missing impact target returns usage 2 without a report"
else
  fail "missing impact target exit/report behavior mismatch (got ${DI_MISSING_EC})"
fi
DI_INVALID_ID_REPORT="${DI_PROBE}/invalid-id.json"
set +e
"${BORIS}" impact ../escape --input="${DI_CONTENT}" --format=json --report="${DI_INVALID_ID_REPORT}" --quiet
DI_INVALID_ID_EC=$?
set -e
if [[ "${DI_INVALID_ID_EC}" -eq 2 && ! -e "${DI_INVALID_ID_REPORT}" ]]; then
  pass "invalid impact ID returns usage 2 without a report"
else
  fail "invalid impact ID exit/report behavior mismatch (got ${DI_INVALID_ID_EC})"
fi
DI_INVALID_REPORT="${DI_PROBE}/invalid-input.json"
cp "${DI_EXPECTED}/check.json" "${DI_INVALID_REPORT}"
DI_INVALID_BEFORE="$(shasum -a 256 "${DI_INVALID_REPORT}")"
set +e
"${BORIS}" check --input="docs/contracts/fixtures/missing-parent/content" --format=json --report="${DI_INVALID_REPORT}" --quiet
DI_INVALID_EC=$?
set -e
DI_INVALID_AFTER="$(shasum -a 256 "${DI_INVALID_REPORT}")"
if [[ "${DI_INVALID_EC}" -eq 1 && "${DI_INVALID_BEFORE}" == "${DI_INVALID_AFTER}" ]]; then
  pass "invalid graph returns exit 1 and preserves prior report"
else
  fail "invalid graph report publication behavior mismatch (got ${DI_INVALID_EC})"
fi
DI_EMPTY_REPORT="${DI_PROBE}/empty.json"
if "${BORIS}" check --input="docs/contracts/fixtures/documentation-intelligence/edge-cases/empty/content" --format=json --report="${DI_EMPTY_REPORT}" --quiet \
  && grep -q '"pages": 0' "${DI_EMPTY_REPORT}"; then
  pass "empty analysis tree returns exit 0 with zero pages"
else
  fail "empty analysis tree behavior mismatch"
fi
DI_SINGLE_REPORT="${DI_PROBE}/single.json"
set +e
"${BORIS}" check --input="docs/contracts/fixtures/documentation-intelligence/edge-cases/single/content" --format=json --report="${DI_SINGLE_REPORT}" --quiet
DI_SINGLE_EC=$?
set -e
if [[ "${DI_SINGLE_EC}" -eq 0 && -f "${DI_SINGLE_REPORT}" ]] && grep -q '"pages": 1' "${DI_SINGLE_REPORT}"; then
  pass "single-page analysis tree reports its page without failing by default"
else
  fail "single-page analysis tree behavior mismatch (got ${DI_SINGLE_EC})"
fi
DI_SINGLE_STRICT_REPORT="${DI_PROBE}/single-strict.json"
set +e
"${BORIS}" check --input="docs/contracts/fixtures/documentation-intelligence/edge-cases/single/content" --format=json --report="${DI_SINGLE_STRICT_REPORT}" --fail-on-unreferenced --quiet
DI_SINGLE_STRICT_EC=$?
set -e
if [[ "${DI_SINGLE_STRICT_EC}" -eq 1 ]] && diff -u "${DI_SINGLE_REPORT}" "${DI_SINGLE_STRICT_REPORT}" >/dev/null; then
  pass "single-page strict policy returns exit 1 with identical report"
else
  fail "single-page strict policy mismatch (got ${DI_SINGLE_STRICT_EC})"
fi
if [[ ! -d "${GATE_DIR}/di-probe/dist" && ! -d "${GATE_DIR}/di-probe/rag" && ! -d "${GATE_DIR}/di-probe/.boris-cache" ]]; then
  pass "analysis produced no HTML, RAG, or cache artifacts"
else
  fail "analysis produced an unexpected build artifact"
fi

# --- 4e. Explicit bounded Textile adapter ---------------------------------
note "4e. Textile adapter mode, outputs, determinism, and failures"
TEXTILE_ROOT="docs/contracts/fixtures/textile-compatibility"
TEXTILE_IR="${GATE_DIR}/textile-ir"
TEXTILE_HTML_A="${GATE_DIR}/textile-html-a"
TEXTILE_HTML_B="${GATE_DIR}/textile-html-b"
TEXTILE_RAG="${GATE_DIR}/textile-rag"
TEXTILE_LAYOUT="test/fixtures/html/layouts/main.html"

"${BORIS}" --textile --input="${TEXTILE_ROOT}/content" --out="${TEXTILE_IR}" --quiet
if grep -q '"sourcePath": "guides/intro.textile"' "${TEXTILE_IR}/graph.json" \
  && grep -q '"kind": "parent"' "${TEXTILE_IR}/graph.json"; then
  pass "Textile IR preserves source identity and Trunk/Satellite parent edge"
else
  fail "Textile IR lost source identity or parent edge"
fi

"${BORIS}" --textile --input="${TEXTILE_ROOT}/content" --html-dir="${TEXTILE_HTML_A}" --html-layout="${TEXTILE_LAYOUT}" --jobs=1 --quiet
"${BORIS}" --textile --input="${TEXTILE_ROOT}/content" --html-dir="${TEXTILE_HTML_B}" --html-layout="${TEXTILE_LAYOUT}" --jobs=4 --quiet
if diff -rq "${TEXTILE_HTML_A}" "${TEXTILE_HTML_B}" >/dev/null; then
  pass "Textile sequential and parallel HTML trees are byte-identical"
else
  fail "Textile sequential and parallel HTML trees differ"
fi
if grep -q '<strong>strong</strong>' "${TEXTILE_HTML_A}/index.html" \
  && grep -q '<ins>inserted</ins>' "${TEXTILE_HTML_A}/index.html" \
  && grep -q '<ol>' "${TEXTILE_HTML_A}/index.html"; then
  pass "Textile subset reaches the existing Oliver HTML renderer"
else
  fail "Textile HTML is missing contracted rendered forms"
fi

"${BORIS}" --textile --rag --complete --input="${TEXTILE_ROOT}/content" --rag-dir="${TEXTILE_RAG}" --quiet
if grep -q '^# Textile Tribute' "${TEXTILE_RAG}/content/pages/index.md" \
  && ! grep -q '^h1\. Textile Tribute' "${TEXTILE_RAG}/content/pages/index.md"; then
  pass "Textile RAG page contains adapted Markdown rather than raw Textile"
else
  fail "Textile RAG page body was not adapted"
fi

set +e
TEXTILE_BAD_ERR="$("${BORIS}" --textile --input="${TEXTILE_ROOT}/invalid/content" --out="${GATE_DIR}/textile-invalid" 2>&1)"
TEXTILE_BAD_EC=$?
TEXTILE_MIX_ERR="$("${BORIS}" --textile --input="${TEXTILE_ROOT}/mixed/content" --out="${GATE_DIR}/textile-mixed" 2>&1)"
TEXTILE_MIX_EC=$?
TEXTILE_DEFAULT_ERR="$("${BORIS}" --input="${TEXTILE_ROOT}/mixed/content" --out="${GATE_DIR}/textile-default-mixed" 2>&1)"
TEXTILE_DEFAULT_EC=$?
set -e
if [[ "${TEXTILE_BAD_EC}" -eq 1 ]] && grep -q 'ETEXTILE' <<<"${TEXTILE_BAD_ERR}"; then
  pass "unsupported/malformed Textile fails loud with ETEXTILE"
else
  fail "invalid Textile exit/category mismatch (exit ${TEXTILE_BAD_EC})"
fi
if [[ "${TEXTILE_MIX_EC}" -eq 1 && "${TEXTILE_DEFAULT_EC}" -eq 1 ]] \
  && grep -q 'ETEXTILE' <<<"${TEXTILE_MIX_ERR}" \
  && grep -q 'ETEXTILE' <<<"${TEXTILE_DEFAULT_ERR}"; then
  pass "mixed Markdown/Textile trees fail in both input modes"
else
  fail "mixed input family did not fail closed in both modes"
fi

# --- 5. Graph fixtures: valid freeze + invalid diagnostics ----------------
note "5. Graph fixtures produce expected valid freezes and invalid diagnostics"
run_bad() {
  local name="$1"
  local code="$2"
  local path="docs/contracts/fixtures/${name}/content"
  local out="${GATE_DIR}/ir-${name}"
  rm -rf "${out}"
  set +e
  err="$("${BORIS}" --input="${path}" --out="${out}" --quiet 2>&1)"
  ec=$?
  set -e
  if [[ "${ec}" -ne 1 ]]; then
    fail "${name}: expected exit 1, got ${ec}"
  else
    pass "${name}: exit 1"
  fi
  if ! grep -q "${code}" <<<"${err}"; then
    # Also check build-report if written
    if [[ -f "${out}/build-report.json" ]] && grep -q "${code}" "${out}/build-report.json"; then
      pass "${name}: ${code} in build-report"
    else
      fail "${name}: missing diagnostic ${code}"
      printf '%s\n' "${err}" | head -20
    fi
  else
    pass "${name}: ${code} on stderr"
  fi
}

run_good() {
  local name="$1"
  local path="docs/contracts/fixtures/${name}/content"
  local out="${GATE_DIR}/ir-${name}"
  rm -rf "${out}"
  if "${BORIS}" --input="${path}" --out="${out}" --quiet \
    && grep -q '"frozen": true' "${out}/graph.json"; then
    pass "${name}: valid graph fixture freezes successfully"
  else
    fail "${name}: expected valid graph fixture to freeze"
  fi
}

run_bad missing-parent EPARENTMISSING
run_bad self-parent EPARENTSELF
run_bad cycles EPARENTCYCLE
run_bad longer-cycle EPARENTCYCLE
run_good satellite-of-satellite
run_bad duplicate-ids EDUPLICATEID
run_bad malformed-frontmatter EFRONTMATTER
run_bad duplicate-key EFRONTMATTER
run_bad invalid-status EFRONTMATTER
run_bad invalid-tags EFRONTMATTER
run_bad invalid-id EINVALIDPATH
run_bad unsupported-syntax EFRONTMATTER

# --- 7. No untracked generated output except approved directories -------------
# Intent: product *output* (dist/rag/.boris/…) must not be committed, and any
# leftover untracked generated trees must be only the approved gitignored set.
# Ordinary source may be untracked during WIP checkouts — that is not a gate fail.
#
# Git detection must use a Git-native worktree check. Linked worktrees have
# `.git` as a *file* (gitdir pointer), not a directory — so `[[ -d .git ]]`
# falsely skips this step. Prefer `git rev-parse --is-inside-work-tree`.
note "7. No untracked generated output except approved directories"
if ! command -v git >/dev/null; then
  pass "skip git cleanliness (git not on PATH)"
elif ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  pass "skip git cleanliness (not a git checkout)"
else
  is_generated_path() {
    case "$1" in
      dist|dist/*|packages|packages/*|rag|rag/*|rag1|rag1/*|rag2|rag2/*|.boris|.boris/*|.boris-*|.boris-*/*|test-output|test-output/*|.release-gate|.release-gate/*|.zig-cache|.zig-cache/*|zig-out|zig-out/*) return 0 ;;
      # Nested build output from standalone tools (tools/<name>/zig-out/...).
      # Without these the root-anchored patterns above miss a tool's binaries.
      */zig-out|*/zig-out/*|*/.zig-cache|*/.zig-cache/*) return 0 ;;
      *) return 1 ;;
    esac
  }
  is_approved_generated() {
    # Approved to exist as local/untracked (and normally gitignored).
    case "$1" in
      dist|dist/*|packages|packages/*|rag|rag/*|rag1|rag1/*|rag2|rag2/*|.boris|.boris/*|.boris-*|.boris-*/*|test-output|test-output/*|.release-gate|.release-gate/*|.zig-cache|.zig-cache/*|zig-out|zig-out/*) return 0 ;;
      # Nested build output from standalone tools (tools/<name>/zig-out/...).
      # Without these the root-anchored patterns above miss a tool's binaries.
      */zig-out|*/zig-out/*|*/.zig-cache|*/.zig-cache/*) return 0 ;;
      *) return 1 ;;
    esac
  }

  bad_tracked=0
  while IFS= read -r f; do
    [[ -z "${f}" ]] && continue
    if is_generated_path "${f}"; then
      bad_tracked=1
      echo "    tracked generated: ${f}"
    fi
  done < <(git ls-files 2>/dev/null || true)
  if [[ "${bad_tracked}" -eq 1 ]]; then
    fail "generated product paths are tracked by git"
  else
    pass "no generated product paths tracked"
  fi

  # Untracked paths that look generated but are *not* in the approved set
  # (e.g. accidental out/ or pages.json at repo root).
  untracked_bad=0
  while IFS= read -r line; do
    [[ -z "${line}" ]] && continue
    path="${line:3}"
    path="${path%/}"
    case "${path}" in
      .DS_Store|*/.DS_Store) continue ;;
    esac
    # Only care about generated-looking names
    case "${path}" in
      dist|dist/*|packages|packages/*|rag|rag/*|rag[0-9]*|rag[0-9]*/*|.boris|.boris/*|.boris-*|.boris-*/*|test-output|test-output/*|.release-gate|.release-gate/*|.zig-cache|.zig-cache/*|zig-out|zig-out/*|out|out/*|.boris-*/*)
        if ! is_approved_generated "${path}"; then
          untracked_bad=1
          echo "    untracked generated (not approved): ${path}"
        fi
        ;;
      manifest.json|graph.json|build-report.json|pages.json|catalog.jsonl|catalog_meta.json)
        untracked_bad=1
        echo "    untracked IR/RAG artifact at repo root: ${path}"
        ;;
    esac
  done < <(git status --porcelain --untracked-files=all 2>/dev/null | grep '^??' || true)
  if [[ "${untracked_bad}" -eq 1 ]]; then
    fail "untracked generated output outside approved directories"
  else
    pass "no disallowed untracked generated artifacts"
  fi
fi

# --- 9. Optional review package (not ship-blocking) ----------------------
# Produces packages/boris-package.tar for maintainer inspection. Failure here
# does not fail the gate (package step is optional for v0.1).
note "9. Optional review package (non-blocking)"
if zig build package -- --input="${VALID_CONTENT}" --packages-dir="${GATE_DIR}/packages" --quiet; then
  if [[ -f "${GATE_DIR}/packages/boris-package.tar" ]]; then
    pass "zig build package wrote ${GATE_DIR}/packages/boris-package.tar"
  else
    pass "zig build package exited 0 (archive path not under gate dir — inspect packages/)"
  fi
else
  pass "zig build package skipped/failed (optional; not a gate fail)"
fi

# --- Summary -------------------------------------------------------------
echo
if [[ "${FAIL}" -ne 0 ]]; then
  echo "RELEASE GATE FAILED"
  exit 1
fi
echo "RELEASE GATE PASSED"
exit 0
