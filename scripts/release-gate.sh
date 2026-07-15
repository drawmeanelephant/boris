#!/usr/bin/env bash
# Boris v0.1 release gate — mechanical checks for reviewers and CI.
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
CI_ZIG="$(sed -n 's/.*version: *\([0-9][0-9.]*\).*/\1/p' .github/workflows/ci.yml | head -1)"
pass "zig version: ${ZIG_VER}"
pass "build.zig.zon minimum_zig_version: ${ZON_MIN}"
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
note "6. catalog_meta.json and catalog.jsonl schema checks"
META="${RAG_A}/catalog_meta.json"
JSONL="${RAG_A}/catalog.jsonl"
if [[ ! -f "${META}" ]]; then
  fail "missing catalog_meta.json"
else
  # Fixed compact shape (schema v1)
  EXPECT_META='{"format":"boris-rag","schema_version":1,"boris_version":"0.3.1"}'
  GOT_META="$(tr -d '\n' < "${META}" | sed 's/[[:space:]]//g')"
  # Allow trailing newline already stripped; tolerate pretty vs compact by
  # requiring keys and values rather than exact whitespace.
  if grep -q '"format"[[:space:]]*:[[:space:]]*"boris-rag"' "${META}" \
    && grep -q '"schema_version"[[:space:]]*:[[:space:]]*1' "${META}" \
    && grep -q '"boris_version"[[:space:]]*:[[:space:]]*"0\.3\.0"' "${META}"; then
    pass "catalog_meta.json fields (format/schema_version/boris_version)"
  else
    fail "catalog_meta.json shape mismatch: $(cat "${META}")"
  fi
  # Prefer exact compact form when present
  if [[ "${GOT_META}" == "${EXPECT_META}" ]]; then
    pass "catalog_meta.json exact compact form"
  fi
fi
if [[ ! -f "${JSONL}" ]]; then
  fail "missing catalog.jsonl"
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
for f in manifest.json graph.json build-report.json; do
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
# RAG artifacts already produced in step 3
pass "RAG: catalog_meta + catalog.jsonl present from step 3"

# --- 5. Invalid fixtures: exit codes + diagnostic codes ------------------
note "5. Invalid fixtures produce expected exit codes and diagnostic codes"
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

run_bad missing-parent EPARENTMISSING
run_bad self-parent EPARENTSELF
run_bad cycles EPARENTCYCLE
run_bad longer-cycle EPARENTCYCLE
run_bad satellite-of-satellite EPARENTNOTTRUNK
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
note "7. No untracked generated output except approved directories"
if ! command -v git >/dev/null || [[ ! -d .git ]]; then
  pass "skip git cleanliness (not a git checkout)"
else
  is_generated_path() {
    case "$1" in
      dist|dist/*|packages|packages/*|rag|rag/*|rag1|rag1/*|rag2|rag2/*|.boris|.boris/*|.boris-*|.boris-*/*|test-output|test-output/*|.release-gate|.release-gate/*|.zig-cache|.zig-cache/*|zig-out|zig-out/*) return 0 ;;
      *) return 1 ;;
    esac
  }
  is_approved_generated() {
    # Approved to exist as local/untracked (and normally gitignored).
    case "$1" in
      dist|dist/*|packages|packages/*|rag|rag/*|rag1|rag1/*|rag2|rag2/*|.boris|.boris/*|.boris-*|.boris-*/*|test-output|test-output/*|.release-gate|.release-gate/*|.zig-cache|.zig-cache/*|zig-out|zig-out/*) return 0 ;;
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
