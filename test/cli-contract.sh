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

# Check and impact preserve their documented reports. Ordinary unreferenced
# findings are informational unless the explicit CI policy flag is selected.
expect_exit 0 "${BORIS}" check --input="${FIXTURE}" --format=json --report="${TMP}/check.json" --quiet
cmp "${EXPECTED}/check.json" "${TMP}/check.json"
expect_exit 1 "${BORIS}" check --input="${FIXTURE}" --format=json --report="${TMP}/check-strict.json" --fail-on-unreferenced --quiet
cmp "${TMP}/check.json" "${TMP}/check-strict.json"
"${BORIS}" impact guides/reference --input="${FIXTURE}" --format=json --report="${TMP}/impact.json" --quiet
cmp "${EXPECTED}/impact.json" "${TMP}/impact.json"

# Repeated output is byte-identical, including the graph/source-location
# projection consumed by editor integrations.
expect_exit 0 "${BORIS}" check --input="${FIXTURE}" --format=json --report="${TMP}/check-repeat.json" --quiet
cmp "${TMP}/check.json" "${TMP}/check-repeat.json"
grep -q '"sourceLocations"' "${TMP}/check.json"
grep -q '"diagnostics": \[\]' "${TMP}/check.json"

# Content, usage, and I/O failures stay distinct and do not create an analysis
# report when no valid frozen graph exists.
expect_exit 1 "${BORIS}" check --input="${INVALID}" --format=json --report="${TMP}/invalid.json" --quiet
test ! -e "${TMP}/invalid.json"
expect_exit 1 "${BORIS}" check --input="${INVALID}" --format=json --report="${TMP}/invalid-strict.json" --fail-on-unreferenced --quiet
test ! -e "${TMP}/invalid-strict.json"
expect_exit 2 "${BORIS}" impact does/not-exist --input="${FIXTURE}" --format=json --report="${TMP}/missing.json" --quiet
test ! -e "${TMP}/missing.json"
expect_exit 3 "${BORIS}" check --input="${MISSING}" --format=json --report="${TMP}/io.json" --quiet
test ! -e "${TMP}/io.json"

# The rendered-output audit catches literal source links as well as .html
# routes, and classifies the invalid publication as content (exit 1).
LINK_FIXTURE="test/fixtures/doc-links-missing/content"
LINK_OUT="${TMP#${ROOT}/}/missing-link-site"
LINK_LOG="${TMP}/missing-link.log"
set +e
"${BORIS}" build --input="${LINK_FIXTURE}" --html-dir="${LINK_OUT}" >"${LINK_LOG}" 2>&1
LINK_EC=$?
set -e
if [[ "${LINK_EC}" -eq 1 ]] && grep -q 'EROUTEMISSING.*missing.md' "${LINK_LOG}" \
  && grep -q 'EROUTEMISSING.*missing.html' "${LINK_LOG}" \
  && test ! -e "${LINK_OUT}/index.html"; then
  :
else
  printf 'missing-link audit mismatch (got exit %s)\n' "${LINK_EC}" >&2
  cat "${LINK_LOG}" >&2
  exit 1
fi

# --profile is a metadata opt-in, not an HTML target selector. Exercise the
# profile workspace (different from cwd) and prove every missing target setting
# fails before any write, while matching CLI settings retain Nostr/Standard.site.
PROFILE_ROOT="${TMP}/profile-site"
PROFILE_REL="${PROFILE_ROOT#${ROOT}/}"
mkdir -p "${PROFILE_ROOT}/content" "${PROFILE_ROOT}/themes/custom/layouts" "${PROFILE_ROOT}/static"
cat >"${PROFILE_ROOT}/content/home.md" <<'EOF'
---
id: home
title: Home
status: published
published_at: 2024-01-20T14:30:00Z
summary: Profile test page.
---

# Home

Hello from the profile test.
EOF
printf '<html><head>{{head}}</head><body>{{content}}</body></html>\n' \
  >"${PROFILE_ROOT}/themes/custom/layouts/main.html"
printf '<html><head>{{head}}</head><body>PROFILE-HOME {{content}}</body></html>\n' \
  >"${PROFILE_ROOT}/themes/custom/layouts/home.html"
printf 'User-agent: *\nDisallow:\n' >"${PROFILE_ROOT}/static/robots.txt"
cat >"${PROFILE_ROOT}/boris.json" <<'EOF'
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "site": { "url": "https://example.test/", "title": "Test", "description": "Profile test." },
  "publication": {
    "target": "github-pages", "base_url": "https://example.test/",
    "origin": "https://example.test/", "base_path": ""
  },
  "targets": [{
    "name": "public", "output": "dist", "public": true,
    "theme": "themes/custom",
    "layout_rules": [{ "selector": "id:home", "layout": "themes/custom/layouts/home.html" }],
    "static": { "dir": "static" }
  }],
  "nostr": {
    "enabled": true,
    "pubkey": "a695f6b60119d9521934a691347d9f78e8770b56da16bb255ee286ddf9fda919",
    "articles": ["home"], "relays": ["wss://relay.example.com"]
  }
}
EOF
PROFILE_LOG="${PROFILE_ROOT}/build.log"
expect_profile_refusal() {
  local field="$1"
  shift
  set +e
  "${BORIS}" build --input="${PROFILE_REL}/content" --profile="${PROFILE_REL}/boris.json" \
    --quiet "$@" >"${PROFILE_LOG}" 2>&1
  local actual=$?
  set -e
  if [[ "${actual}" -ne 2 ]] || ! grep -q -- "--profile.*${field}" "${PROFILE_LOG}" \
    || [[ -e "${PROFILE_ROOT}/dist" ]]; then
    printf 'profile HTML refusal mismatch for %s (exit %s)\n' "${field}" "${actual}" >&2
    cat "${PROFILE_LOG}" >&2
    exit 1
  fi
}
expect_profile_refusal "name"
expect_profile_refusal "theme" --target="public=${PROFILE_REL}/dist"
expect_profile_refusal "layout_rules" --target="public=${PROFILE_REL}/dist" \
  --theme="${PROFILE_REL}/themes/custom"
expect_profile_refusal "static" --target="public=${PROFILE_REL}/dist" \
  --theme="${PROFILE_REL}/themes/custom" \
  --layout-rule public id:home "${PROFILE_REL}/themes/custom/layouts/home.html"
cat >"${PROFILE_ROOT}/edition.json" <<'EOF'
{"format":"boris-publication-profile","schema_version":1,"editions":{"ir":{"output":".boris"}}}
EOF
set +e
"${BORIS}" build --profile="${PROFILE_REL}/edition.json" --quiet >"${PROFILE_LOG}" 2>&1
EDITION_EC=$?
set -e
if [[ "${EDITION_EC}" -ne 2 ]] || ! grep -q 'declares editions.ir' "${PROFILE_LOG}" \
  || [[ -e "${PROFILE_ROOT}/dist" ]]; then
  printf 'profile edition refusal mismatch (exit %s)\n' "${EDITION_EC}" >&2
  cat "${PROFILE_LOG}" >&2
  exit 1
fi

PROFILE_FLAGS=(--input="${PROFILE_REL}/content" --profile="${PROFILE_REL}/boris.json"
  --target="public=${PROFILE_REL}/dist" --theme="${PROFILE_REL}/themes/custom"
  --layout-rule public id:home "${PROFILE_REL}/themes/custom/layouts/home.html"
  --static-dir="${PROFILE_REL}/static" --quiet)
"${BORIS}" build "${PROFILE_FLAGS[@]}"
grep -q 'PROFILE-HOME' "${PROFILE_ROOT}/dist/home.html"
grep -q 'nostr:naddr1' "${PROFILE_ROOT}/dist/home.html"
cmp "${PROFILE_ROOT}/static/robots.txt" "${PROFILE_ROOT}/dist/robots.txt"

# A matching Standard.site profile still emits the established verification
# files and head links; the guard must not ban --profile wholesale.
cat >"${PROFILE_ROOT}/standard-site.json" <<'EOF'
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "site": { "url": "https://example.test/", "title": "Test", "description": "Profile test." },
  "publication": {
    "target": "standard-site", "base_url": "https://example.test/",
    "origin": "https://example.test/", "base_path": "",
    "did": "did:plc:ewvi7nxzyoun6zhxrhs64oiz"
  },
  "targets": [{
    "name": "public", "output": "dist", "public": true,
    "theme": "themes/custom",
    "layout_rules": [{ "selector": "id:home", "layout": "themes/custom/layouts/home.html" }],
    "static": { "dir": "static" },
    "sitemap": { "path": "sitemap.xml" }
  }]
}
EOF
STANDARD_FLAGS=("${PROFILE_FLAGS[@]}")
STANDARD_FLAGS[1]="--profile=${PROFILE_REL}/standard-site.json"
set +e
"${BORIS}" build "${STANDARD_FLAGS[@]}" >"${PROFILE_LOG}" 2>&1
SITEMAP_EC=$?
set -e
if [[ "${SITEMAP_EC}" -ne 2 ]] || ! grep -q -- '--profile HTML target.*sitemap' "${PROFILE_LOG}" \
  || ! grep -q 'nostr:naddr1' "${PROFILE_ROOT}/dist/home.html"; then
  printf 'profile sitemap refusal mismatch (exit %s)\n' "${SITEMAP_EC}" >&2
  cat "${PROFILE_LOG}" >&2
  exit 1
fi
STANDARD_FLAGS+=(--sitemap --site-url="https://example.test/")
"${BORIS}" build "${STANDARD_FLAGS[@]}"
test -f "${PROFILE_ROOT}/dist/_boris/proof/standard-site.json"
grep -q 'site.standard.document' "${PROFILE_ROOT}/dist/home.html"
test -f "${PROFILE_ROOT}/dist/sitemap.xml"

printf 'CLI contract process tests: PASS\n'
