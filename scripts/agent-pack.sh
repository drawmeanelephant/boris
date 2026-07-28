#!/usr/bin/env bash
set -euo pipefail

# Build a reproducible handoff archive containing Boris's installed CLIs.
# The archive is intentionally separate from boris-package: this is a
# developer/agent transport artifact, not a product IR or RAG package.

usage() {
  cat <<'EOF'
Usage: scripts/agent-pack.sh [options]

Build and archive the Boris binaries for handoff to another agent.

Options:
  --out DIR       Output directory (default: boris-agent-kit)
  --no-build      Use already-installed binaries; do not run Zig builds
  --allow-dirty   Permit uncommitted changes; the manifest records this
  -h, --help      Show this help

The default run requires a clean worktree and builds Boris plus its standalone
developer tools. The resulting archive is named by the source commit:
  DIR/boris-agent-kit-<commit>.tar.gz
EOF
}

repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"

out_dir="boris-agent-kit"
do_build=1
allow_dirty=0

while (($# > 0)); do
  case "$1" in
    --out)
      (($# >= 2)) || { echo "--out requires a directory" >&2; exit 2; }
      out_dir=$2
      shift 2
      ;;
    --out=*) out_dir=${1#*=}; shift ;;
    --no-build) do_build=0; shift ;;
    --allow-dirty) allow_dirty=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$out_dir" ]]; then
  echo "output directory must not be empty" >&2
  exit 2
fi

status=$(git status --porcelain=v1)
dirty=0
if [[ -n "$status" ]]; then
  dirty=1
  if (( ! allow_dirty )); then
    echo "refusing to pack a dirty worktree; commit changes or pass --allow-dirty" >&2
    printf '%s\n' "$status" >&2
    exit 1
  fi
fi

commit=$(git rev-parse HEAD)
branch=$(git branch --show-current)
short_commit=$(git rev-parse --short=12 HEAD)
zig_version=$(zig version)
platform=$(uname -s)-$(uname -m)

if (( do_build )); then
  echo "building root Boris binaries..."
  zig build
  echo "building standalone developer tools..."
  zig build --build-file tools/search-index/build.zig
  zig build --build-file tools/migration-lab/build.zig
  zig build --build-file tools/docs-maintenance/build.zig
fi

declare -a names=(
  boris
  boris-package
  boris-source-rag
  boris-search-index
  boris-migration-lab
  boris-docs-maintenance
)
declare -a sources=(
  zig-out/bin/boris
  zig-out/bin/boris-package
  zig-out/bin/boris-source-rag
  tools/search-index/zig-out/bin/boris-search-index
  tools/migration-lab/zig-out/bin/boris-migration-lab
  tools/docs-maintenance/zig-out/bin/boris-docs-maintenance
)

for source in "${sources[@]}"; do
  if [[ ! -f "$source" || ! -x "$source" ]]; then
    echo "missing executable: $source" >&2
    echo "run without --no-build or build the corresponding tool first" >&2
    exit 1
  fi
done

stage=$(mktemp -d "${TMPDIR:-/tmp}/boris-agent-pack.XXXXXX")
cleanup() { rm -rf "$stage"; }
trap cleanup EXIT

root="$stage/boris-agent-kit"
mkdir -p "$root/bin"

for i in "${!names[@]}"; do
  install -m 0755 "${sources[$i]}" "$root/bin/${names[$i]}"
done

json_escape() {
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/	/\\t/g; s/\r/\\r/g; s/$/\\n/' | tr -d '\n' | sed 's/\\n$//'
}

escaped_branch=$(json_escape "$branch")
escaped_zig=$(json_escape "$zig_version")
escaped_platform=$(json_escape "$platform")

{
  printf '{\n'
  printf '  "format": "boris-agent-kit",\n'
  printf '  "schema_version": 1,\n'
  printf '  "repository": "drawmeanelephant/boris",\n'
  printf '  "commit": "%s",\n' "$commit"
  printf '  "branch": "%s",\n' "$escaped_branch"
  printf '  "dirty": %s,\n' "$([[ $dirty -eq 1 ]] && echo true || echo false)"
  printf '  "platform": "%s",\n' "$escaped_platform"
  printf '  "zig_version": "%s",\n' "$escaped_zig"
  printf '  "binaries": [\n'
  for i in "${!names[@]}"; do
    digest=$(shasum -a 256 "${sources[$i]}" | awk '{print $1}')
    comma=,
    (( i == ${#names[@]} - 1 )) && comma=
    printf '    {"name":"%s","path":"bin/%s","sha256":"%s"}%s\n' "${names[$i]}" "${names[$i]}" "$digest" "$comma"
  done
  printf '  ]\n'
  printf '}\n'
} > "$root/MANIFEST.json"

cat > "$root/README.md" <<EOF
# Boris agent binary kit

This archive contains the Boris executables built from commit $commit on
branch $branch for $platform with Zig $zig_version.

Start with the machine-readable MANIFEST.json. Verify the payload with
SHA256SUMS, then run the appropriate executable from bin/. These are native
binaries and must match the recorded platform.

This kit is a transport artifact for agent handoff. It is not the product
IR/RAG package and does not replace the repository source checkout.
EOF

(
  cd "$root"
  for file in bin/*; do
    digest=$(shasum -a 256 "$file" | awk '{print $1}')
    printf '%s  %s\n' "$digest" "$file"
  done
) > "$root/SHA256SUMS"

# Normalize every archive input. The explicit sorted file list plus fixed
# ownership/modes/times keeps the tar and gzip bytes stable across runs on the
# same platform and commit.
find "$stage" -type d -exec chmod 0755 {} +
find "$stage" -type f -exec touch -t 197001010000 {} +

mkdir -p "$out_dir"
archive="$out_dir/boris-agent-kit-$short_commit.tar.gz"
tmp_tar="$stage/boris-agent-kit.tar"
tmp_archive="$out_dir/.boris-agent-kit-$short_commit.tar.gz.tmp"
file_list="$stage/file-list.txt"
(
  cd "$stage"
  find boris-agent-kit -type f -print | LC_ALL=C sort
) > "$file_list"

tar -cf "$tmp_tar" \
  --format=ustar \
  --uid 0 --gid 0 --uname '' --gname '' \
  -C "$stage" -T "$file_list"
gzip -n -c "$tmp_tar" > "$tmp_archive"
mv -f "$tmp_archive" "$archive"

(
  cd "$out_dir"
  shasum -a 256 "$(basename "$archive")"
) > "$archive.sha256"
echo "wrote $archive"
echo "sha256: $(awk '{print $1}' "$archive.sha256")"
