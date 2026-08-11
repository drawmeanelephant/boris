#!/usr/bin/env bash
# Focused black-box test for the Pages public/evidence artifact boundary.
set -euo pipefail

ROOT=$(mktemp -d "${TMPDIR:-/tmp}/boris-pages-artifact-test.XXXXXX")
cleanup() {
  status=$?
  rm -rf "$ROOT"
  exit "$status"
}
trap cleanup EXIT

SOURCE="$ROOT/source"
DEST="$ROOT/public"
INVENTORY="$SOURCE/_boris/proof/artifacts.json"
mkdir -p "$SOURCE/assets" "$SOURCE/_boris/search" "$SOURCE/_boris/proof"
printf '%s\n' '<!doctype html><title>Boris</title>' > "$SOURCE/index.html"
printf '%s\n' 'body { color: #333; }' > "$SOURCE/assets/site.css"
printf '%s\n' '{"documents":[]}' > "$SOURCE/_boris/search/search-index.json"
printf '%s\n' '{"private":true}' > "$SOURCE/_boris/proof/checks.json"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

index_sha=$(hash_file "$SOURCE/index.html")
css_sha=$(hash_file "$SOURCE/assets/site.css")
search_sha=$(hash_file "$SOURCE/_boris/search/search-index.json")
index_bytes=$(wc -c < "$SOURCE/index.html")
css_bytes=$(wc -c < "$SOURCE/assets/site.css")
search_bytes=$(wc -c < "$SOURCE/_boris/search/search-index.json")
jq -n \
  --arg index_sha "$index_sha" --arg css_sha "$css_sha" --arg search_sha "$search_sha" \
  --argjson index_bytes "$index_bytes" --argjson css_bytes "$css_bytes" --argjson search_bytes "$search_bytes" \
  '{format:"boris-publication-artifacts",schema_version:1,target:"public",artifacts:[
    {path:"_boris/search/search-index.json",kind:"rendered-search",producer:"rendered-search",required:true,status:"committed",bytes:$search_bytes,sha256:$search_sha,format_version:null},
    {path:"assets/site.css",kind:"theme-asset",producer:"theme-assets",required:true,status:"committed",bytes:$css_bytes,sha256:$css_sha,format_version:null},
    {path:"index.html",kind:"html-page",producer:"html-render",required:true,status:"committed",bytes:$index_bytes,sha256:$index_sha,format_version:null}
  ]}' > "$INVENTORY"

scripts/prepare-github-pages-artifact.sh "$SOURCE" "$DEST" "$INVENTORY" public "$ROOT/summary.json"
test -f "$DEST/index.html"
test -f "$DEST/assets/site.css"
test -f "$DEST/_boris/search/search-index.json"
test ! -e "$DEST/_boris/proof/checks.json"
jq -e '(.files == 3) and (.proof_paths_excluded == true) and ((.public_manifest_sha256 | type) == "string")' "$ROOT/summary.json" >/dev/null

jq 'del(.artifacts[] | select(.path == "index.html"))' "$INVENTORY" > "$ROOT/missing-index.json"
if scripts/prepare-github-pages-artifact.sh "$SOURCE" "$ROOT/missing-index" "$ROOT/missing-index.json" public >/dev/null 2>&1; then
  echo "missing index was accepted" >&2
  exit 1
fi

if ln -s "index.html" "$SOURCE/symlink.html" 2>/dev/null; then
  if scripts/prepare-github-pages-artifact.sh "$SOURCE" "$ROOT/symlink" "$INVENTORY" public >/dev/null 2>&1; then
    echo "symlinked source was accepted" >&2
    exit 1
  fi
  rm -f "$SOURCE/symlink.html"
fi

if ln "$SOURCE/index.html" "$SOURCE/hardlink.html" 2>/dev/null; then
  if scripts/prepare-github-pages-artifact.sh "$SOURCE" "$ROOT/hardlink" "$INVENTORY" public >/dev/null 2>&1; then
    echo "hard-linked source was accepted" >&2
    exit 1
  fi
  rm -f "$SOURCE/hardlink.html"
fi

echo "github-pages-artifact: black-box checks passed"
