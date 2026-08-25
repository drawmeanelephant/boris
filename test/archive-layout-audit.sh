#!/usr/bin/env bash
# Black-box audit for the realistic archive-layout acceptance fixture.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT}"

BORIS="${1:-${ROOT}/zig-out/bin/boris}"
if [[ ! -x "${BORIS}" ]]; then
  zig build
fi

FIXTURE="docs/contracts/fixtures/archive-layout-audit"
TMP_REL=".archive-layout-audit-${$}"
TMP="${ROOT}/${TMP_REL}"
OUT_REL="${TMP_REL}/site"
REPEAT_REL="${TMP_REL}/repeat"
OUT="${ROOT}/${OUT_REL}"
REPEAT="${ROOT}/${REPEAT_REL}"
AUDIT="${TMP}/link-audit"
mkdir -p "${TMP}"
trap 'rm -rf "${TMP}"' EXIT

render() {
  local destination="$1"
  "${BORIS}" \
    --input "${FIXTURE}/content" \
    --theme "${FIXTURE}/theme" \
    --layout-rule default id:archive "${FIXTURE}/theme/layouts/archive.html" \
    --layout-rule default role:trunk "${FIXTURE}/theme/layouts/section.html" \
    --html-dir "${destination}" \
    --quiet
}

render "${OUT_REL}"
render "${REPEAT_REL}"
diff -rq "${OUT}" "${REPEAT}"

# Effective layouts: id selector wins for root; role selector wins for Trunks;
# direct Satellites retain the main fallback.
grep -q 'data-layout="archive"' "${OUT}/archive.html"
for path in years/2024.html years/2025.html topics/field-notes.html; do
  grep -q 'data-layout="section"' "${OUT}/${path}"
done
grep -q 'data-layout="entry"' "${OUT}/years/2024/010-kickoff.html"

# Direct children are entity-id ordered, and empty Trunks have no wrapper.
children="${OUT}/years/2024.html"
grep -q 'page-children' "${children}"
first=$(grep -n '010-kickoff.html' "${children}" | head -n1 | cut -d: -f1)
last=$(grep -n '080-last-light.html' "${children}" | head -n1 | cut -d: -f1)
test "${first}" -lt "${last}"
! grep -q 'page-children' "${OUT}/topics/field-notes.html"
! grep -q 'page-children' "${OUT}/archive.html"

# Nested output paths, parent breadcrumb, rich content, and page-local asset.
test -f "${OUT}/years/2024/010-kickoff.assets/diagram.svg"
grep -q '010-kickoff.assets/diagram.svg' "${OUT}/years/2024/010-kickoff.html"
grep -q 'href="../2024.html"' "${OUT}/years/2024/010-kickoff.html"
grep -q 'page-toc' "${OUT}/years/2024/010-kickoff.html"
grep -q 'admonition' "${OUT}/years/2024/010-kickoff.html"
grep -q '<details class="details"' "${OUT}/years/2024/010-kickoff.html"

# Source-level mechanical guardrails for narrow widths and overflow risk.
css="${FIXTURE}/theme/assets/archive-audit.css"
grep -q 'overflow-wrap: anywhere' "${css}"
grep -q 'overflow-x: auto' "${css}"
grep -q '@media (max-width: 42rem)' "${css}"
grep -q 'grid-template-columns: 1fr' "${css}"

mkdir -p "${AUDIT}"
zig build --build-file tools/migration-lab/build.zig run -- \
  --mode=link-audit --root="${OUT}" --out="${AUDIT}" --quiet
grep -q 'Found \*\*0\*\* local-link findings' "${AUDIT}/REPORT.md"

printf 'Archive layout audit: PASS\n'
