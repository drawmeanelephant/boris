#!/usr/bin/env bash
# XHTML output-profile evidence guard (#448, acceptance criterion 5): Boris's
# own docs content must be able to publish a page under the XHTML profile and
# that page must verify well-formed under an independent XML parser, so the
# profile seam cannot rot silently.
#
# Run from the repository root, or through:
#
#   zig build test-xhtml-evidence
#
# All generated trees live under the ignored .zig-cache tree.
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/xhtml-evidence"
[[ "$OUT" == ".zig-cache/xhtml-evidence" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/content" "$OUT/layouts"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# A real contract-style page with no raw HTML — the XHTML-safe subset.
# NOTE: no footnotes on purpose — the pinned Oliver's footnote markers
# (data-footnote-ref / data-footnotes / data-footnote-backref) are hardcoded
# valueless attributes and are not yet XML-valid under the XHTML profile
# (tracked upstream; see docs/contracts/oliver-renderer.md). The profile's
# own hard-break and escaping behavior is what this guard pins.
cat > "$OUT/content/index.md" <<'MD'
# Publication artifacts contract

This page exercises the XHTML profile. Hard breaks use two trailing spaces
and no verbatim raw HTML appears — an XHTML target fails closed on raw HTML
by design, so this page must stay clean.

A hard break follows.  
And a list:

- a code span `x < y` (must be escaped)
- an entity `AT&T` (must be escaped)
MD

# The XHTML document wrapper is a layout concern: XML declaration + xmlns on
# the html element; the page-body slot receives the XHTML fragment.
cat > "$OUT/layouts/main.html" <<'HTML'
<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml" data-layout="main">
<head>
  <meta charset="utf-8" />
  <title>{{title}}</title>
</head>
<body data-layout="main">
  <main id="main-content">{{content}}</main>
</body>
</html>
HTML

"$BORIS" build \
  --input "$OUT/content" \
  --theme "$OUT" \
  --target site="$OUT/site" \
  --target-profile site=xhtml \
  --quiet

PAGE="$OUT/site/index.html"
[[ -f "$PAGE" ]] || fail "expected XHTML page at site/index.html"

# Independent well-formedness check. Prefer xmllint (libxml2) when present —
# the same tool Oliver's own XHTML verification used — else the stdlib
# ElementTree via python3 (present on both CI runners).
if command -v xmllint >/dev/null 2>&1; then
    xmllint --noout "$PAGE" 2>&1 | sed 's/^/    /'
    pass "xmllint: site/index.html is well-formed XML"
else
    python3 - "$PAGE" <<'PY'
import sys
import xml.etree.ElementTree as ET
ET.parse(sys.argv[1])
PY
    pass "python3 ElementTree: site/index.html is well-formed XML"
fi

# The document must carry the XHTML namespace, and the fragment serializer
# must never have fabricated a fake wrapper: exactly one <html> element, and
# it is the layout's (line 2, after the XML declaration).
grep -q 'xmlns="http://www.w3.org/1999/xhtml"' "$PAGE" \
    || fail "XHTML namespace missing from document wrapper"
html_tags="$(grep -c '<html' "$PAGE" || true)"
[[ "$html_tags" == "1" ]] || fail "expected exactly 1 <html> element, got ${html_tags}"
sed -n '1,2p' "$PAGE" | grep -q '<?xml version="1.0"' \
    || fail "XML declaration missing at document head"
pass "document wrapper carries the XHTML namespace + declaration; no fake wrappers"

note "XHTML evidence verified: $(wc -c < "$PAGE" | tr -d ' ') bytes, $(grep -c '<' "$PAGE" | tr -d ' ') tags"
