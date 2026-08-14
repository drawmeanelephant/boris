#!/usr/bin/env bash
# Black-box guard for the teaching layer's internal links (#394): every
# relative Markdown link in README.md and docs/authoring-spine.md must
# resolve to a real file or directory, and a heading anchor must match a
# GitHub-style slug of a heading in the target Markdown. Also asserts the
# spine keeps its six-step shape, so the teaching layer cannot rot silently.
# Runs on every PR inside `zig build test`.
#
#   zig build test-doc-links
#
# NOTE: bash 3.2 compatibility is deliberate (macOS /bin/bash); no
# associative arrays, no bash-4+isms — a vacuous pass would defeat the guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

FILES=(README.md docs/authoring-spine.md)
failures=0

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

# Walk every inline link and reference-style definition in a Markdown file
# (skipping fenced code blocks) and fail on broken relative targets.
check_file() {
  local src="$1" line target path frag resolved
  while IFS='|' read -r line target; do
    [ -n "$target" ] || continue
    case "$target" in
      http://*|https://*|mailto:*|ftp://*|//*) continue ;;  # external
    esac
    path="${target%%#*}"
    frag="${target#*#}"
    [ "$frag" = "$target" ] && frag=""
    [ -n "$path" ] || path="$src"  # bare #anchor lives in this file
    case "$path" in
      /*) resolved="$ROOT$path" ;;
      *)  resolved="$(dirname "$src")/$path" ;;
    esac
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
      while (match(line, /\]\([^)]*\)/)) {
        t = substr(line, RSTART + 2, RLENGTH - 3)
        print NR "|" t
        line = substr(line, RSTART + RLENGTH)
      }
    }
    /^[[:space:]]*\[[^]]*\]:/ {
      rest = $0
      sub(/^[[:space:]]*\[[^]]*\]:[[:space:]]*/, "", rest)
      sub(/[[:space:]]*$/, "", rest)
      print NR "|" rest
    }
  ' "$src")
}

note "walking internal links in README.md and the authoring spine"
for file in "${FILES[@]}"; do
  check_file "$file"
done

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
