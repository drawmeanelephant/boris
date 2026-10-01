#!/usr/bin/env bash
# Black-box coverage for the stable Boris command/report contract.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BORIS="${1:-${ROOT}/zig-out/bin/boris}"
if [[ ! -x "${BORIS}" ]]; then
  zig build
fi
if [[ "${BORIS}" != /* ]]; then BORIS="${ROOT}/${BORIS}"; fi

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

# Explicit HTML selectors retain the --profile metadata opt-in. Exercise the
# profile workspace (different from cwd) and prove every unmatched target setting
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
expect_profile_refusal "name" --html
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

# `validate --profile` (#1006): the profile drives a zero-write validation
# pass over its declared targets. Layout paths are workspace-relative only,
# so the invocation runs from the profile workspace root — the same
# convention the build contract documents for profiles. Named HTML selectors
# conflict at parse time; non-executable declarations refuse with exit 2 and
# a named field; the passing run writes nothing but an explicit --report
# file.
rm -rf "${PROFILE_ROOT}/dist"
set +e
"${BORIS}" validate --profile="${PROFILE_REL}/boris.json" --theme="${PROFILE_REL}/themes/custom" \
  --quiet >"${PROFILE_LOG}" 2>&1
THEME_EC=$?
set -e
if [[ "${THEME_EC}" -ne 2 ]] || ! grep -q -- '--profile conflicts with --theme' "${PROFILE_LOG}"; then
  printf 'validate --profile theme-conflict mismatch (exit %s)\n' "${THEME_EC}" >&2
  cat "${PROFILE_LOG}" >&2
  exit 1
fi
cat >"${PROFILE_ROOT}/validate-editions.json" <<'EOF'
{"format":"boris-publication-profile","schema_version":1,"editions":{"ir":{"output":".boris"}}}
EOF
set +e
"${BORIS}" validate --profile="${PROFILE_REL}/validate-editions.json" --quiet >"${PROFILE_LOG}" 2>&1
VEDITION_EC=$?
set -e
if [[ "${VEDITION_EC}" -ne 2 ]] || ! grep -q 'declares editions.ir' "${PROFILE_LOG}"; then
  printf 'validate --profile edition refusal mismatch (exit %s)\n' "${VEDITION_EC}" >&2
  cat "${PROFILE_LOG}" >&2
  exit 1
fi
cat >"${PROFILE_ROOT}/validate-multi.json" <<'EOF'
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "targets": [
    { "name": "alpha", "output": "dist/alpha", "theme": "themes/custom" },
    { "name": "beta", "output": "dist/beta", "theme": "themes/custom" }
  ]
}
EOF
"${BORIS}" validate --profile="${PROFILE_REL}/validate-multi.json" --quiet
test ! -e "${PROFILE_ROOT}/dist"
# Profile-driven validation now honors the declared publication location and
# metadata without publishing a subset or writing output.
"${BORIS}" validate --profile="${PROFILE_REL}/boris.json" --quiet >"${PROFILE_LOG}" 2>&1
test ! -e "${PROFILE_ROOT}/dist"
cat >"${PROFILE_ROOT}/validate-single.json" <<'EOF'
{
  "format": "boris-publication-profile",
  "schema_version": 1,
  "input": "content",
  "site": { "url": "https://example.test/" },
  "targets": [{
    "name": "public", "output": "dist/never", "public": true,
    "theme": "themes/custom",
    "layout_rules": [{ "selector": "id:home", "layout": "themes/custom/layouts/home.html" }],
    "static": { "dir": "static" },
    "sitemap": { "path": "sitemap.xml" }
  }]
}
EOF
( cd "${PROFILE_ROOT}" && "${BORIS}" validate --profile="validate-single.json" \
  --report="${PROFILE_ROOT}/validate-report.json" )
grep -q '"ok": true' "${PROFILE_ROOT}/validate-report.json"
test ! -e "${PROFILE_ROOT}/dist"
test ! -e "${PROFILE_ROOT}/sitemap.xml"
grep -q 'nostr:naddr' "${PROFILE_ROOT}/validate-report.json" && exit 1 || true

# No repeated HTML flags: profile targets, rule layouts, static files, and
# sitemap execute from a different CWD, including outside that CWD's tree.
mkdir -p "${TMP}/caller"
printf '<html><head>{{head}}</head><body>PROFILE-HOME <a href="robots.txt">Robots</a>{{content}}</body></html>\n' \
  >"${PROFILE_ROOT}/themes/custom/layouts/home.html"
cat >"${PROFILE_ROOT}/content/notes.md" <<'EOF'
---
parent: home
title: Notes
---

Profile child page.
EOF
( cd "${TMP}/caller" && "${BORIS}" validate --profile="${PROFILE_ROOT}/validate-single.json" \
  --report="${TMP}/profile-validation.json" --quiet )
test ! -e "${PROFILE_ROOT}/dist"
grep -q "\"contentRoot\": \"${PROFILE_ROOT}/content\"" "${TMP}/profile-validation.json"
( cd "${TMP}/caller" && "${BORIS}" build --profile="${PROFILE_ROOT}/validate-single.json" --quiet )
grep -q 'PROFILE-HOME' "${PROFILE_ROOT}/dist/never/home.html"
test -f "${PROFILE_ROOT}/dist/never/notes.html"
cmp "${PROFILE_ROOT}/static/robots.txt" "${PROFILE_ROOT}/dist/never/robots.txt"
test -f "${PROFILE_ROOT}/dist/never/sitemap.xml"
grep -q '"target": "public"' "${PROFILE_ROOT}/dist/never/_boris/proof/artifacts.json"
test ! -e "${TMP}/caller/dist"
cp -R "${PROFILE_ROOT}/dist/never" "${TMP}/profile-golden"
( cd "${TMP}/caller" && "${BORIS}" build --profile="${PROFILE_ROOT}/validate-single.json" --jobs 2 --quiet )
diff -r "${TMP}/profile-golden" "${PROFILE_ROOT}/dist/never"
( cd "${TMP}/caller" && "${BORIS}" build --profile="${PROFILE_ROOT}/validate-single.json" --jobs 2 --quiet )
diff -r "${TMP}/profile-golden" "${PROFILE_ROOT}/dist/never"
"${BORIS}" validate --profile="${PROFILE_ROOT}/validate-single.json" --quiet
diff -r "${TMP}/profile-golden" "${PROFILE_ROOT}/dist/never"
# Equivalent legacy CLI-only selection remains byte-identical.
( cd "${PROFILE_ROOT}" && "${BORIS}" build --input content --target public=dist/never \
  --theme themes/custom --layout-rule public id:home themes/custom/layouts/home.html \
  --static-dir static --sitemap --site-url https://example.test/ --quiet )
diff -r "${TMP}/profile-golden" "${PROFILE_ROOT}/dist/never"

# Metadata surfaces still work without repeated target flags.
"${BORIS}" build --profile="${PROFILE_ROOT}/boris.json" --quiet
grep -q 'nostr:naddr1' "${PROFILE_ROOT}/dist/home.html"
"${BORIS}" build --profile="${PROFILE_ROOT}/standard-site.json" --quiet
grep -q 'site.standard.document' "${PROFILE_ROOT}/dist/home.html"
test -f "${PROFILE_ROOT}/dist/_boris/proof/standard-site.json"
"${BORIS}" validate --profile="${PROFILE_ROOT}/standard-site.json" --quiet
expect_exit 2 "${BORIS}" watch --profile="${PROFILE_ROOT}/standard-site.json" --quiet

# Every declared plain HTML target runs, in canonical name order.
"${BORIS}" build --profile="${PROFILE_ROOT}/validate-multi.json" --quiet
test -f "${PROFILE_ROOT}/dist/alpha/home.html"
test -f "${PROFILE_ROOT}/dist/beta/home.html"

# Unsupported entries fail before overwriting an existing publication, even
# when another target would be executable. No subset publication is allowed.
sed 's/"sitemap": { "path": "sitemap.xml" }/"rss": { "path": "rss.xml" }/' \
  "${PROFILE_ROOT}/standard-site.json" >"${PROFILE_ROOT}/unsupported-rss.json"
cp -R "${PROFILE_ROOT}/dist" "${TMP}/before-refusal"
expect_exit 2 "${BORIS}" build --profile="${PROFILE_ROOT}/unsupported-rss.json" --quiet
expect_exit 2 "${BORIS}" validate --profile="${PROFILE_ROOT}/unsupported-rss.json" --quiet
expect_exit 2 "${BORIS}" watch --profile="${PROFILE_ROOT}/unsupported-rss.json" --quiet
diff -r "${TMP}/before-refusal" "${PROFILE_ROOT}/dist"
expect_exit 2 "${BORIS}" build --profile="${PROFILE_ROOT}/validate-single.json" --input ../escape --quiet
cp -R "${PROFILE_ROOT}/content" "${PROFILE_ROOT}/other-content"
printf '\nProfile input override.\n' >>"${PROFILE_ROOT}/other-content/home.md"
"${BORIS}" build --profile="${PROFILE_ROOT}/validate-single.json" --input other-content --quiet
grep -q 'Profile input override' "${PROFILE_ROOT}/dist/never/home.html"
"${BORIS}" validate --profile="${PROFILE_ROOT}/validate-single.json" --input other-content --quiet
expect_exit 2 "${BORIS}" watch --profile="${PROFILE_ROOT}/validate-single.json" --theme themes/custom --quiet

# Strict is a complete-site target, not a bare Oliver body switch. The
# compatible theme builds; the default HTML5 theme fails as a content error
# with one located diagnostic and no phantom fallback.
STRICT_INPUT="fixtures/html4-strict/content"
expect_exit 0 "${BORIS}" build --input="${STRICT_INPUT}" \
  --theme themes/html4-strict --target-profile default=html4-strict \
  --html-dir="${TMP#${ROOT}/}/strict-site" --quiet
grep -q 'HTML 4.01//EN' "${TMP}/strict-site/index.html"
grep -q 'HTML 4.01//EN' "${TMP}/strict-site/_boris/proof/index.html"
expect_exit 1 "${BORIS}" validate --input="${STRICT_INPUT}" \
  --target-profile default=html4-strict --report="${TMP}/strict-invalid.json" --quiet
grep -q '"errorCount": 1' "${TMP}/strict-invalid.json"
grep -q '"code": "EHTML4STRICT"' "${TMP}/strict-invalid.json"
grep -q 'themes/boris/layouts/main.html' "${TMP}/strict-invalid.json"

printf 'CLI contract process tests: PASS\n'
