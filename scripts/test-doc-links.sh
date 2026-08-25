#!/usr/bin/env bash
# Black-box guard for the documentation's internal links (#394): every
# relative Markdown link in README.md and the whole authored docs/ tree
# (contracts, audits, dogfood, changelog.d, top-level docs) must resolve to
# a real file or directory, and a heading anchor must match a GitHub-style
# slug of a heading in the target Markdown. Also asserts the authoring
# spine keeps its six-step shape, so the documentation cannot rot silently.
# Runs on every PR inside `zig build test`.
#
#   zig build test-doc-links
#
# Skipped by design: fenced code blocks and inline code spans (code is not
# navigation) and external protocols (http/https/mailto/ftp/file). Whole-tree
# and link-level exclusions live in scripts/doc-links-exclusions.txt, with a
# comment per entry — see that file for why fixture test data are excluded
# and which links are archival by intent.
#
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms — a vacuous pass would defeat the guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

failures=0
links_checked=0

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; failures=$((failures + 1)); }

# GitHub-style heading slug: lowercase, drop punctuation (keep word chars,
# spaces, hyphens), spaces -> single hyphens. Repeated headings on one page
# get -N suffixes on GitHub; a link may point at either form.
slugify() {
  printf '%s' "$*" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[^a-z0-9 _-]//g' -e 's/  */-/g'
}

# Does the Markdown file contain a heading whose slug matches the wanted
# anchor (or its -N repeated form)?
has_heading_slug() {
  local md="$1" wanted="$2"
  local bare="$wanted"
  [[ "$wanted" =~ -[0-9]+$ ]] && bare="${wanted%-[0-9]*}"
  local heading slug
  while IFS= read -r heading; do
    [ -n "$heading" ] || continue
    slug="$(slugify "$heading")"
    if [ "$slug" = "$wanted" ] || [ "$slug" = "$bare" ]; then
      return 0
    fi
  done < <(awk '
    /^```/ { in_fence = !in_fence; next }
    in_fence { next }
    /^#{1,6}[[:space:]]/ { line = $0; sub(/^#+[[:space:]]+/, "", line); print line }
  ' "$md")
  return 1
}

EXCLUSIONS_FILE="scripts/doc-links-exclusions.txt"

# Load the exclusion manifest into TREES (glob patterns) and LINKS
# ("src|target" exact matches). A missing, empty, or unparseable manifest is
# a hard failure: the guard must never vacuously pass because its blind
# spots were accidentally widened.
load_exclusions() {
  local line
  TREES=()
  LINKS=()
  [ -f "$EXCLUSIONS_FILE" ] || {
    echo "doc-links: missing exclusion manifest $EXCLUSIONS_FILE" >&2
    exit 1
  }
  while IFS= read -r line; do
    case "$line" in
      ""|\#*) continue ;;
      "tree "*) TREES+=("${line#tree }") ;;
      "link "*) LINKS+=("${line#link }") ;;
      *) echo "doc-links: unparseable exclusion line: '$line' (in $EXCLUSIONS_FILE)" >&2; exit 1 ;;
    esac
  done < "$EXCLUSIONS_FILE"
  if [ "${#TREES[@]}" -eq 0 ] && [ "${#LINKS[@]}" -eq 0 ]; then
    echo "doc-links: exclusion manifest $EXCLUSIONS_FILE has no entries" >&2
    exit 1
  fi
}

# Is this repo-relative markdown path inside an excluded tree? Matches the
# manifest's `tree` globs (case-style globs match across path separators).
is_skipped_tree() {
  local glob
  for glob in "${TREES[@]}"; do
    case "$1" in
      $glob) return 0 ;;
    esac
  done
  return 1
}

# Walk every inline link and reference-style definition in a Markdown file
# (skipping fenced code blocks and inline code spans) and fail on broken
# relative targets.
check_file() {
  local src="$1" line target path frag resolved skip entry
  while IFS='|' read -r line target; do
    [ -n "$target" ] || continue
    links_checked=$((links_checked + 1))
    case "$target" in
      http://*|https://*|mailto:*|ftp://*|file://*|//*) continue ;;  # external
    esac
    skip=false
    for entry in "${LINKS[@]}"; do
      if [ "$entry" = "$src|$target" ]; then skip=true; break; fi
    done
    $skip && continue
    path="${target%%#*}"
    frag="${target#*#}"
    [ "$frag" = "$target" ] && frag=""
    if [ -z "$path" ]; then
      resolved="$ROOT/$src"  # bare #anchor lives in this file
    else
      case "$path" in
        /*) resolved="$ROOT$path" ;;
        *)  resolved="$(dirname "$src")/$path" ;;
      esac
    fi
    resolved="${resolved%/}"
    if [ ! -e "$resolved" ]; then
      fail "$src:$line: link '$target' -> '$resolved' does not exist"
      continue
    fi
    if [ -n "$frag" ] && [[ "$resolved" == *.md ]] \
        && ! has_heading_slug "$resolved" "$frag"; then
      fail "$src:$line: link '$target' -> heading '#$frag' not found in $resolved"
      continue
    fi
  done < <(awk '
    /^```/ { in_fence = !in_fence; next }
    in_fence { next }
    {
      line = $0
      gsub(/`[^`]*`/, "", line)  # inline code spans are not links
      while (match(line, /\]\([^)]*\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        print NR "|" t
        line = substr(line, RSTART + RLENGTH)
      }
      # reference-style definitions outside code spans
      while (match(line, /^[[:space:]]*\[[^]]*\]:[[:space:]]*[^[:space:]]+/)) {
        t = substr(line, RSTART, RLENGTH)
        sub(/^[[:space:]]*\[[^]]*\]:[[:space:]]*/, "", t)
        sub(/[[:space:]]*$/, "", t)
        print NR "|" t
        line = substr(line, RSTART + RLENGTH)
      }
    }
  ' "$src")
}

load_exclusions

note "walking internal links in README.md and the whole docs/ tree"
check_file README.md
while IFS= read -r file; do
  [ -n "$file" ] || continue
  is_skipped_tree "$file" && continue
  check_file "$file"
done < <(find docs -name '*.md' | sort)
note "$links_checked links checked"

note "the spine keeps its six-step shape"
for step in \
    "1. Start" "2. Content & frontmatter" "3. Links & graph" \
    "4. Layout" "5. Publish" "6. Verify"; do
  grep -qFx "## $step" docs/authoring-spine.md \
    || fail "docs/authoring-spine.md lost the step heading '## $step'"
done
pass "all six spine steps present"

if [ "$failures" -ne 0 ]; then
  printf 'doc-links: %d broken link(s)\n' "$failures" >&2
  exit 1
fi
echo "doc-links: all assertions passed"
