#!/usr/bin/env bash
# Black-box regression: Cooklang structural warnings (unclosed `{`, `[-`)
# print exactly once on every path — including incremental no-change HTML
# rebuilds, where cache-reused pages skip render entirely. The load-time
# validation pass in `loadAndPromoteFormat` is the only printer (Greptile P1
# fix, #388); this test pins that contract so a future "print at render"
# change cannot silently drop warnings for unchanged pages.
#
# Run from the repository root, or through:
#
#   zig build test-cooklang-incremental-warnings
#
# The generated tree and logs live under the ignored .zig-cache tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/cooklang-incremental-warnings"
[[ "$OUT" == ".zig-cache/cooklang-incremental-warnings" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT/logs"
# Absolute, so every path below stays correct after `cd "$WORK"`.
OUT="$(cd "$OUT" && pwd -P)"
WORK="$OUT/work"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# --- corpus: two pages, one unclosed `{`, one unclosed `[-` ---------------
mkdir -p "$WORK/content" "$WORK/layouts"
cat > "$WORK/content/index.cook" <<'EOF'
---
id: index
title: Warning Corpus
---

Mix @flour{200%g to the bowl.
EOF
cat > "$WORK/content/broken.cook" <<'EOF'
---
id: broken
title: Broken Corpus
---

Stir [- never closed.
EOF
cat > "$WORK/layouts/main.html" <<'EOF'
<!doctype html>
<html>
<body>
{{content}}
</body>
</html>
EOF

warn_count() {
    local stderr_file="$1"
    local needle="$2"
    grep -c --fixed-strings -- "$needle" "$stderr_file" 2>/dev/null || true
}

# --- plain HTML build: each warning exactly once --------------------------
note "plain HTML build"
cd "$WORK"
"$ROOT/zig-out/bin/boris" --cooklang --input content --html-dir dist --html-layout layouts/main.html \
    >"$OUT/logs/plain.stdout" 2>"$OUT/logs/plain.stderr" || fail "plain HTML build exited nonzero"
[[ -f "$WORK/dist/index.html" ]] || fail "plain build wrote no index.html"
[[ -f "$WORK/dist/broken.html" ]] || fail "plain build wrote no broken.html"
braces=$(warn_count "$OUT/logs/plain.stderr" "unclosed-braces")
blocks=$(warn_count "$OUT/logs/plain.stderr" "unclosed-block-comment")
[[ "$braces" -eq 1 ]] || fail "plain build: expected 1 unclosed-braces warning, got $braces"
[[ "$blocks" -eq 1 ]] || fail "plain build: expected 1 unclosed-block-comment warning, got $blocks"
pass "each warning printed exactly once"

# --- incremental rebuilds: warnings still print, even when render is skipped ---
# The plain build does not write the incremental manifest; the first
# incremental run does, and the second reuses it. The regression under test
# is the second run: both pages are cache-reused (render skipped) yet both
# warnings still print, because the load-time validation pass is the printer.
note "incremental rebuild 1 (writes the manifest, full render)"
"$ROOT/zig-out/bin/boris" --cooklang --input content --html-dir dist --html-layout layouts/main.html \
    --incremental \
    >"$OUT/logs/incremental1.stdout" 2>"$OUT/logs/incremental1.stderr" || fail "incremental rebuild 1 exited nonzero"
braces=$(warn_count "$OUT/logs/incremental1.stderr" "unclosed-braces")
blocks=$(warn_count "$OUT/logs/incremental1.stderr" "unclosed-block-comment")
[[ "$braces" -eq 1 ]] || fail "incremental rebuild 1: expected 1 unclosed-braces warning, got $braces"
[[ "$blocks" -eq 1 ]] || fail "incremental rebuild 1: expected 1 unclosed-block-comment warning, got $blocks"
pass "warnings printed exactly once"

note "incremental rebuild 2 (cache-reused pages skip render)"
"$ROOT/zig-out/bin/boris" --cooklang --input content --html-dir dist --html-layout layouts/main.html \
    --incremental --timings \
    >"$OUT/logs/incremental2.stdout" 2>"$OUT/logs/incremental2.stderr" || fail "incremental rebuild 2 exited nonzero"
braces=$(warn_count "$OUT/logs/incremental2.stderr" "unclosed-braces")
blocks=$(warn_count "$OUT/logs/incremental2.stderr" "unclosed-block-comment")
[[ "$braces" -eq 1 ]] || fail "incremental rebuild 2: expected 1 unclosed-braces warning, got $braces"
[[ "$blocks" -eq 1 ]] || fail "incremental rebuild 2: expected 1 unclosed-block-comment warning, got $blocks"
hits=$(grep -oE '"fast_path_hits": [0-9]+' "$OUT/logs/incremental2.stdout" | grep -oE '[0-9]+' || true)
[[ "$hits" == "2" ]] || fail "incremental rebuild 2: expected 2 fast-path hits (both pages reused), got '${hits}'"
pass "warnings still printed once with both pages cache-reused"

# --- pipeline (IR) path: warnings once, artifacts written -----------------
note "pipeline (IR) build"
"$ROOT/zig-out/bin/boris" --cooklang --input content --out ir \
    >"$OUT/logs/ir.stdout" 2>"$OUT/logs/ir.stderr" || fail "IR build exited nonzero"
[[ -f "$WORK/ir/manifest.json" ]] || fail "IR build wrote no manifest.json"
braces=$(warn_count "$OUT/logs/ir.stderr" "unclosed-braces")
blocks=$(warn_count "$OUT/logs/ir.stderr" "unclosed-block-comment")
[[ "$braces" -eq 1 ]] || fail "IR build: expected 1 unclosed-braces warning, got $braces"
[[ "$blocks" -eq 1 ]] || fail "IR build: expected 1 unclosed-block-comment warning, got $blocks"
pass "each warning printed exactly once"

rm -rf "$WORK"
echo "cooklang-incremental-warnings: all assertions passed"
