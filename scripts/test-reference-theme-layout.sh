#!/usr/bin/env bash
# Black-box guard for the layout-rule precedence contract (#400): the
# reference-theme example must select the same layouts regardless of rule
# declaration order (fixed precedence: exact id > glob specificity > role >
# fallback), and the winners must match the documented expectations.
#
# Run from the repository root, or through:
#
#   zig build test-reference-theme-layout
#
# All generated trees live under the ignored .zig-cache tree.
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms — a vacuous pass would defeat the guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/reference-theme-layout"
[[ "$OUT" == ".zig-cache/reference-theme-layout" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

CONTENT="examples/reference-theme/content"
THEME="examples/reference-theme/theme"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# Expected winners from the example README, as "page expected-layout" pairs.
# `index` is a trunk, so both `id:index` and `role:trunk` match it — the
# fixed-precedence contract says the exact id wins; declaration-order
# semantics would make this depend on rule order.
EXPECTED="
index.html home
guides.html section
reference.html section
guides/components.html main
guides/getting-started.html main
reference/slots-and-rules.html main
"

layout_of() { # $1 = out dir, $2 = relative html path; "MISSING" when absent
  local hit
  hit="$(grep -o 'data-layout="[a-z]*"' "$1/$2" | head -1)" || true
  [[ -n "$hit" ]] || { echo "MISSING"; return; }
  echo "$hit" | sed 's/^data-layout="//;s/"$//'
}

check_expected() { # $1 = out dir; fails loudly on any mismatch
  local page expected got
  while read -r page expected; do
    [[ -n "$page" ]] || continue
    got="$(layout_of "$1" "$page")"
    [[ "$got" == "$expected" ]] \
      || fail "$page: expected data-layout=\"$expected\", got \"$got\""
  done <<< "$EXPECTED"
}

build_order_a() { # id:index declared first
  "$ROOT/zig-out/bin/boris" \
    --input "$CONTENT" \
    --theme "$THEME" \
    --layout-rule default id:index "$THEME/layouts/home.html" \
    --layout-rule default role:trunk "$THEME/layouts/section.html" \
    --html-dir "$1" \
    --quiet || fail "order-A build failed"
}

build_order_b() { # role:trunk declared first (order independence proof)
  "$ROOT/zig-out/bin/boris" \
    --input "$CONTENT" \
    --theme "$THEME" \
    --layout-rule default role:trunk "$THEME/layouts/section.html" \
    --layout-rule default id:index "$THEME/layouts/home.html" \
    --html-dir "$1" \
    --quiet || fail "order-B build failed"
}

note "reference-theme builds under both rule declaration orders"
build_order_a "$OUT/a"
build_order_b "$OUT/b"
pass "both orders built (exit 0)"

note "winners match the documented expectations (order A)"
check_expected "$OUT/a"
pass "all six winners correct (id beats role on index; trunks section; satellites main)"

note "declaration order never changes the winner"
check_expected "$OUT/b"
pass "identical winners with role:trunk declared first"

note "output trees are byte-identical across declaration orders"
diff -r "$OUT/a" "$OUT/b" >/dev/null \
  || fail "order-A and order-B output trees differ"
pass "byte-identical trees"

note "theme and page-local assets published"
for f in \
    "assets/css/reference.css" \
    "assets/img/mark.svg" \
    "index.assets/rhythm-diagram.svg" \
    "guides/components.assets/component-flow.svg"; do
  [[ -f "$OUT/a/$f" ]] || fail "missing published asset: $f"
done
pass "assets present"

rm -rf "$OUT"
echo "reference-theme-layout: all assertions passed"
