#!/usr/bin/env bash
# Black-box coverage for the stable Boris command/report contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BORIS="${1:-${ROOT}/zig-out/bin/boris}"
if [[ ! -x "${BORIS}" ]]; then
  zig build
fi

FIXTURE="docs/contracts/fixtures/documentation-intelligence/content"
EXPECTED="docs/contracts/fixtures/documentation-intelligence/expected"
INVALID="docs/contracts/fixtures/missing-parent/content"
MISSING="docs/contracts/fixtures/documentation-intelligence/not-a-real-root"
TMP="${ROOT}/.release-gate-cli-contract-${$}"
rm -rf "${TMP}"
mkdir -p "${TMP}"
trap 'rm -rf "${TMP}"' EXIT

expect_exit() {
  local expected="$1"
  shift
  set +e
  "$@"
  local actual=$?
  set -e
  if [[ "${actual}" -ne "${expected}" ]]; then
    printf 'expected exit %s, got %s: %s\n' "${expected}" "${actual}" "$*" >&2
    exit 1
  fi
}

# Explicit build routes to the existing IR contract and publishes all three
# successful artifacts under a workspace-relative output path.
"${BORIS}" build --input="${FIXTURE}" --out="${TMP}/ir" --quiet
for artifact in manifest.json graph.json build-report.json; do
  test -f "${TMP}/ir/${artifact}"
done

# Explicit watch routes through the command parser without starting a session.
"${BORIS}" watch --help >/dev/null 2>&1

# Check and impact preserve their documented exit behavior and JSON goldens.
expect_exit 1 "${BORIS}" check --input="${FIXTURE}" --format=json --report="${TMP}/check.json" --quiet
cmp "${EXPECTED}/check.json" "${TMP}/check.json"
"${BORIS}" impact guides/reference --input="${FIXTURE}" --format=json --report="${TMP}/impact.json" --quiet
cmp "${EXPECTED}/impact.json" "${TMP}/impact.json"

# Repeated output is byte-identical, including the graph/source-location
# projection consumed by editor integrations.
expect_exit 1 "${BORIS}" check --input="${FIXTURE}" --format=json --report="${TMP}/check-repeat.json" --quiet
cmp "${TMP}/check.json" "${TMP}/check-repeat.json"
grep -q '"sourceLocations"' "${TMP}/check.json"
grep -q '"diagnostics": \[\]' "${TMP}/check.json"

# Content, usage, and I/O failures stay distinct and do not create an analysis
# report when no valid frozen graph exists.
expect_exit 1 "${BORIS}" check --input="${INVALID}" --format=json --report="${TMP}/invalid.json" --quiet
test ! -e "${TMP}/invalid.json"
expect_exit 2 "${BORIS}" impact does/not-exist --input="${FIXTURE}" --format=json --report="${TMP}/missing.json" --quiet
test ! -e "${TMP}/missing.json"
expect_exit 3 "${BORIS}" check --input="${MISSING}" --format=json --report="${TMP}/io.json" --quiet
test ! -e "${TMP}/io.json"

printf 'CLI contract process tests: PASS\n'
