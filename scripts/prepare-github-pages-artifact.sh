#!/usr/bin/env bash
# Verify and copy exactly the Boris-owned payloads for a GitHub Pages upload.
# The target-local proof reports remain outside the public artifact.
set -euo pipefail

usage() {
  echo "usage: $0 SOURCE_DIR DEST_DIR INVENTORY_JSON TARGET_NAME [SUMMARY_JSON]" >&2
  exit 2
}

[[ $# -ge 4 && $# -le 5 ]] || usage

SOURCE_DIR=$1
DEST_DIR=$2
INVENTORY_JSON=$3
TARGET_NAME=$4
SUMMARY_JSON=${5:-}
MAX_BYTES=${BORIS_PAGES_MAX_BYTES:-1073741824}

fail() {
  echo "github-pages-artifact: $*" >&2
  exit 1
}

[[ -d "$SOURCE_DIR" && ! -L "$SOURCE_DIR" ]] || fail "source directory is not a real directory: $SOURCE_DIR"
[[ -f "$INVENTORY_JSON" && ! -L "$INVENTORY_JSON" ]] || fail "inventory is not a regular file: $INVENTORY_JSON"
command -v jq >/dev/null 2>&1 || fail "jq is required"
[[ "$MAX_BYTES" =~ ^[0-9]+$ ]] || fail "BORIS_PAGES_MAX_BYTES must be an integer"

if [[ -e "$DEST_DIR" || -L "$DEST_DIR" ]]; then
  [[ -d "$DEST_DIR" && ! -L "$DEST_DIR" ]] || fail "destination is not a real directory: $DEST_DIR"
  [[ -z "$(find -P "$DEST_DIR" -mindepth 1 -print -quit)" ]] || fail "destination must be empty: $DEST_DIR"
else
  mkdir -p "$DEST_DIR"
fi

if find -P "$SOURCE_DIR" -type l -print -quit | grep -q .; then
  fail "source contains a symlink"
fi
if find -P "$SOURCE_DIR" -type f -links +1 -print -quit | grep -q .; then
  fail "source contains a hard-linked regular file"
fi

jq -e --arg target "$TARGET_NAME" '
  .format == "boris-publication-artifacts" and
  .schema_version == 1 and
  .target == $target and
  (.artifacts | type == "array" and length > 0) and
  (([.artifacts[].path] | unique | length) == (.artifacts | length)) and
  all(.artifacts[]; (
    .status == "committed" and
    ((.path | type) == "string") and
    ((.bytes | type) == "number") and
    (.bytes >= 0 and (.bytes == (.bytes | floor))) and
    ((.sha256 | type) == "string") and
    (.sha256 | test("^[0-9a-f]{64}$"))
  ))
' "$INVENTORY_JSON" >/dev/null || fail "inventory is not a supported committed artifact inventory"

hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

inventory_sha256=$(hash_file "$INVENTORY_JSON")
binding_file=$(mktemp "${TMPDIR:-/tmp}/boris-pages-binding.XXXXXX")
cleanup() {
  status=$?
  rm -f "$binding_file"
  exit "$status"
}
trap cleanup EXIT

files=0
total_bytes=0
index_seen=0
while IFS=$'\t' read -r path expected_bytes expected_sha; do
  [[ -n "$path" && -n "$expected_bytes" && -n "$expected_sha" ]] || fail "inventory contains an empty record"
  case "$path" in
    /*|*\\*|*//*|.|./*|*/.|../*|*/../*|_boris/proof|_boris/proof/*|.boris-cache|.boris-cache/*)
      fail "unsafe or private artifact path: $path"
      ;;
  esac
  IFS='/' read -r -a segments <<< "$path"
  for segment in "${segments[@]}"; do
    [[ -n "$segment" && "$segment" != "." && "$segment" != ".." ]] || fail "unsafe artifact path: $path"
  done

  source_path="$SOURCE_DIR/$path"
  destination_path="$DEST_DIR/$path"
  [[ -f "$source_path" && ! -L "$source_path" ]] || fail "inventoried file is missing or not regular: $path"
  actual_bytes=$(wc -c < "$source_path")
  actual_bytes=${actual_bytes//[[:space:]]/}
  [[ "$actual_bytes" == "$expected_bytes" ]] || fail "byte count mismatch: $path"
  actual_sha=$(hash_file "$source_path")
  [[ "$actual_sha" == "$expected_sha" ]] || fail "SHA-256 mismatch: $path"
  mkdir -p "$(dirname "$destination_path")"
  cp "$source_path" "$destination_path"
  copied_bytes=$(wc -c < "$destination_path")
  copied_bytes=${copied_bytes//[[:space:]]/}
  [[ "$copied_bytes" == "$expected_bytes" ]] || fail "copied byte count mismatch: $path"
  copied_sha=$(hash_file "$destination_path")
  [[ "$copied_sha" == "$expected_sha" ]] || fail "copied SHA-256 mismatch: $path"

  printf '%s\0%s\0%s\0' "$path" "$expected_bytes" "$expected_sha" >> "$binding_file"
  files=$((files + 1))
  total_bytes=$((total_bytes + expected_bytes))
  [[ "$total_bytes" -le "$MAX_BYTES" ]] || fail "public artifact exceeds ${MAX_BYTES}-byte limit"
  [[ "$path" == "index.html" ]] && index_seen=1
done < <(jq -r '.artifacts[] | [.path, (.bytes | tostring), .sha256] | @tsv' "$INVENTORY_JSON")

[[ "$index_seen" == 1 ]] || fail "inventory does not include top-level index.html"
[[ -f "$DEST_DIR/index.html" && ! -L "$DEST_DIR/index.html" ]] || fail "public artifact lacks top-level index.html"
[[ -z "$(find -P "$DEST_DIR" -type l -print -quit)" ]] || fail "destination contains a symlink"
[[ -z "$(find -P "$DEST_DIR" -type f -links +1 -print -quit)" ]] || fail "destination contains a hard-linked regular file"
destination_files=$(find -P "$DEST_DIR" -type f | wc -l)
destination_files=${destination_files//[[:space:]]/}
[[ "$destination_files" == "$files" ]] || fail "destination contains files outside the inventory"

public_manifest_sha256=$(hash_file "$binding_file")
summary=$(jq -n \
  --arg target "$TARGET_NAME" \
  --arg inventory_sha256 "$inventory_sha256" \
  --arg public_manifest_sha256 "$public_manifest_sha256" \
  --argjson files "$files" \
  --argjson bytes "$total_bytes" \
  --argjson max_bytes "$MAX_BYTES" \
  '{
    format: "boris-github-pages-artifact-verification",
    schema_version: 1,
    target: $target,
    files: $files,
    bytes: $bytes,
    max_bytes: $max_bytes,
    inventory_sha256: $inventory_sha256,
    public_manifest_sha256: $public_manifest_sha256,
    index_path: "index.html",
    proof_paths_excluded: true,
    symlinks_rejected: true,
    hard_links_rejected: true
  }')

if [[ -n "$SUMMARY_JSON" ]]; then
  mkdir -p "$(dirname "$SUMMARY_JSON")"
  printf '%s\n' "$summary" > "$SUMMARY_JSON"
else
  printf '%s\n' "$summary"
fi
echo "github-pages-artifact: verified ${files} files (${total_bytes} bytes) for ${TARGET_NAME}" >&2
