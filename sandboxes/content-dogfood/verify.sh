#!/usr/bin/env bash
# Accept content-dogfood sandbox against a built Boris binary.
# Run from repo root: ./sandboxes/content-dogfood/verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SB="$ROOT/sandboxes/content-dogfood"
BORIS="${BORIS:-$ROOT/zig-out/bin/boris}"
CONTENT="$SB/content"
LAYOUT="$SB/layouts/main.html"
OUT="$SB/out"

if [[ ! -x "$BORIS" ]]; then
  echo "error: missing $BORIS — run 'zig build' at repo root first" >&2
  exit 3
fi

if [[ ! -d "$CONTENT" || ! -f "$LAYOUT" ]]; then
  echo "error: sandbox content or layout missing under $SB" >&2
  exit 3
fi

rm -rf "$OUT"
mkdir -p "$OUT"

echo "== HTML =="
"$BORIS" --quiet \
  --input "$CONTENT" \
  --html-dir "$OUT/dist" \
  --html-layout "$LAYOUT"
test -f "$OUT/dist/index.html"

echo "== IR =="
"$BORIS" --quiet \
  --input "$CONTENT" \
  --out "$OUT/ir"
test -f "$OUT/ir/manifest.json"
test -f "$OUT/ir/graph.json"

echo "== RAG =="
"$BORIS" --quiet \
  --input "$CONTENT" \
  --rag-dir "$OUT/rag"
test -f "$OUT/rag/INDEX.md"
test -d "$OUT/rag/content/pages"

echo "ok: content-dogfood sandbox (HTML + IR + RAG)"
