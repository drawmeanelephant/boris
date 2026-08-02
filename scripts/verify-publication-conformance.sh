#!/usr/bin/env bash
# Executable black-box conformance verification for the retained C01–C08
# publication evidence (Textile, includes/fragments, sitemap, RSS, layout
# precedence, cache/watch, asset collisions/SVG, parser/Unicode). Run from the
# repository root, or through:
#
#   zig build test-publication-conformance
#
# All generated source and output paths are deterministic, repository-relative,
# and owned by the ignored .zig-cache tree. No timestamps, randomness, or
# absolute paths enter the Boris inputs.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
BORIS_ABS="$ROOT/zig-out/bin/boris"
OUT=".zig-cache/publication-conformance"
C01="docs/audits/publication-conformance/c01-textile"
C02="docs/audits/publication-conformance/c02-includes-fragments"
C03="docs/audits/publication-conformance/c03-sitemap"
C04="docs/audits/publication-conformance/c04-rss"
C05="docs/audits/publication-conformance/c05-layout-precedence"
C06="docs/audits/publication-conformance/c06-cache-watch"
C07="docs/audits/publication-conformance/c07-asset-collisions"
C08="docs/audits/publication-conformance/c08-parser-unicode"
LAYOUT="$C02/layout.html"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

[[ -x "$BORIS" ]] || fail "missing installed Boris binary at ${BORIS}"
[[ -f "$C02/depth-cases.psv" ]] || fail "missing generated-depth declaration"

# This path is fixed and ignored by the repository. Keep the guard adjacent to
# the cleanup so a future edit cannot accidentally widen the deletion scope.
[[ "$OUT" == ".zig-cache/publication-conformance" ]] || fail "unsafe verifier output path"
rm -rf "$OUT"
mkdir -p "$OUT/logs" "$OUT/outputs" "$OUT/generated" "$OUT/snapshots"
WATCH_PIDS=()
cleanup() {
    for pid in "${WATCH_PIDS[@]:-}"; do
        kill -TERM "$pid" 2>/dev/null || true
    done
    # Reap every retained watcher (errors suppressed) before removing the
    # workspace so no background Boris process survives an assertion failure.
    for pid in "${WATCH_PIDS[@]:-}"; do
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$OUT"
}
trap cleanup EXIT

run_capture() {
    local name="$1"
    local expected_exit="$2"
    shift 2
    local stdout="$OUT/logs/${name}.stdout"
    local stderr="$OUT/logs/${name}.stderr"
    local actual_exit

    if "$@" >"$stdout" 2>"$stderr"; then
        actual_exit=0
    else
        actual_exit=$?
    fi
    if [[ "$actual_exit" -ne "$expected_exit" ]]; then
        printf '%s\n' "--- ${name} stdout" >&2
        sed -n '1,120p' "$stdout" >&2 || true
        printf '%s\n' "--- ${name} stderr" >&2
        sed -n '1,160p' "$stderr" >&2 || true
        fail "${name}: expected exit ${expected_exit}, got ${actual_exit}"
    fi
}

assert_empty() {
    local path="$1"
    [[ ! -s "$path" ]] || fail "expected empty stream: ${path}"
}

assert_nonempty() {
    local path="$1"
    [[ -s "$path" ]] || fail "expected non-empty stream: ${path}"
}

assert_absent() {
    local path="$1"
    [[ ! -e "$path" ]] || fail "unexpected publication target exists: ${path}"
}

assert_no_html_target() {
    local path="$1"
    [[ ! -e "$path/index.html" ]] || fail "unexpected final HTML target exists: ${path}/index.html"
    if [[ -e "$path" && -n "$(find "$path" -mindepth 1 -print -quit)" ]]; then
        find "$path" -mindepth 1 -maxdepth 3 -print >&2
        fail "unexpected HTML artifacts exist under failed target: ${path}"
    fi
}

# The IR contract publishes build-report.json on content failure, but never
# publishes graph.json or manifest.json: docs/contracts/diagnostics.md.
assert_failed_ir_state() {
    local path="$1"
    assert_absent "$path/graph.json"
    assert_absent "$path/manifest.json"
    assert_file "$path/build-report.json"
    assert_contains '"ok": false' "$path/build-report.json"
}

assert_file() {
    local path="$1"
    [[ -f "$path" ]] || fail "expected file is missing: ${path}"
}

assert_cmp() {
    local expected="$1"
    local actual="$2"
    if ! cmp "$expected" "$actual"; then
        diff -u "$expected" "$actual" >&2 || true
        fail "artifact mismatch: ${actual}"
    fi
}

assert_diag() {
    local expected="$1"
    local actual="$2"
    if ! cmp "$expected" "$actual"; then
        diff -u "$expected" "$actual" >&2 || true
        fail "diagnostic mismatch: ${actual}"
    fi
}

assert_tree_equal() {
    local left="$1"
    local right="$2"
    local diff_path="$OUT/logs/tree-diff-$(basename "$left").txt"
    if ! diff -ru "$left" "$right" >"$diff_path"; then
        cat "$diff_path" >&2
        fail "deterministic tree mismatch: ${left} vs ${right}"
    fi
}

assert_contains() {
    local needle="$1"
    local path="$2"
    grep -F "$needle" "$path" >/dev/null || fail "${path} does not contain ${needle}"
}

# Published-payload equality that tolerates the incremental-manifest subtree
# (a clean build writes no .boris-cache; an incremental build does).
assert_page_equal() {
    local left="$1"
    local right="$2"
    local diff_path="$OUT/logs/page-diff-$(basename "$left")-$(basename "$right").txt"
    if ! diff -ru "$left" "$right" --exclude=.boris-cache >"$diff_path"; then
        cat "$diff_path" >&2
        fail "published payload mismatch: ${left} vs ${right}"
    fi
}

wait_for_grep() {
    local file="$1"
    local needle="$2"
    local tries="${3:-100}"
    local i
    for i in $(seq 1 "$tries"); do
        grep -qF "$needle" "$file" 2>/dev/null && return 0
        sleep 0.2
    done
    return 1
}

wait_pid_exit() {
    local pid="$1"
    local tries="${2:-100}"
    local i
    for i in $(seq 1 "$tries"); do
        if ! kill -0 "$pid" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

run_html_success() {
    local name="$1"
    local input="$2"
    local expected_html="$3"
    shift 3
    local first="$OUT/outputs/${name}-a"
    local second="$OUT/outputs/${name}-b"

    run_capture "${name}-a" 0 "$BORIS" --html --input "$input" --html-dir "$first" --html-layout "$LAYOUT" --quiet "$@"
    assert_empty "$OUT/logs/${name}-a.stdout"
    assert_empty "$OUT/logs/${name}-a.stderr"
    assert_file "$first/index.html"
    assert_cmp "$expected_html" "$first/index.html"

    run_capture "${name}-b" 0 "$BORIS" --html --input "$input" --html-dir "$second" --html-layout "$LAYOUT" --quiet "$@"
    assert_empty "$OUT/logs/${name}-b.stdout"
    assert_empty "$OUT/logs/${name}-b.stderr"
    assert_tree_equal "$first" "$second"
    pass "${name}: exit 0, golden, and repeat tree"
}

run_html_failure() {
    local name="$1"
    local input="$2"
    local expected_stderr="$3"
    shift 3
    local output="$OUT/outputs/${name}"
    run_capture "$name" 1 "$BORIS" --html --input "$input" --html-dir "$output" --html-layout "$LAYOUT" "$@"
    assert_empty "$OUT/logs/${name}.stdout"
    assert_diag "$expected_stderr" "$OUT/logs/${name}.stderr"
    assert_no_html_target "$output"
    pass "${name}: exit 1, exact diagnostic, no final HTML target"
}

note "C02 includes and heading fragments"
run_html_success "c02-01" "$C02/cases/01-include-success/content" "$C02/cases/01-include-success/expected/index.html"
run_html_failure "c02-02" "$C02/cases/02-missing-include/content" "$C02/cases/02-missing-include/expected/stderr.txt"
run_html_failure "c02-03" "$C02/cases/03-direct-cycle/content" "$C02/cases/03-direct-cycle/expected/stderr.txt"
run_html_failure "c02-04" "$C02/cases/04-long-cycle/content" "$C02/cases/04-long-cycle/expected/stderr.txt"
run_html_success "c02-05" "$C02/cases/05-valid-fragment/content" "$C02/cases/05-valid-fragment/expected/index.html"
run_html_failure "c02-06" "$C02/cases/06-missing-fragment/content" "$C02/cases/06-missing-fragment/expected/stderr.txt"
run_html_success "c02-07" "$C02/cases/07-fragment-after-include/content" "$C02/cases/07-fragment-after-include/expected/index.html"
run_html_success "c02-08" "$C02/cases/08-duplicate-heading/content" "$C02/cases/08-duplicate-heading/expected/index.html"
assert_cmp "$C02/cases/08-duplicate-heading/expected/target.html" "$OUT/outputs/c02-08-a/target.html"
run_html_success "c02-09" "$C02/cases/09-nested-include-path/content" "$C02/cases/09-nested-include-path/expected/index.html"

generate_depth_case() {
    local root="$1"
    local depth="$2"
    local title="$3"
    local marker="$4"
    local i level next

    mkdir -p "$root/content/includes"
    printf '%s\n' '---' "title: ${title}" '---' '{{include includes/level-01.md}}' >"$root/content/index.md"
    i=1
    while [[ "$i" -le "$depth" ]]; do
        level="$(printf '%02d' "$i")"
        if [[ "$i" -lt "$depth" ]]; then
            next="$(printf '%02d' "$((i + 1))")"
            printf '{{include includes/level-%s.md}}\n' "$next" >"$root/content/includes/level-${level}.md"
        else
            printf '%s\n' "$marker" >"$root/content/includes/level-${level}.md"
        fi
        i=$((i + 1))
    done
}

while IFS='|' read -r name depth title marker expected_exit expected_html expected_stderr; do
    [[ -z "$name" || "$name" == \#* ]] && continue
    generated="$OUT/generated/$name"
    generate_depth_case "$generated/a" "$depth" "$title" "$marker"
    generate_depth_case "$generated/b" "$depth" "$title" "$marker"
    assert_tree_equal "$generated/a/content" "$generated/b/content"
    input="$generated/a/content"
    output="$OUT/outputs/$name"
    if [[ "$expected_exit" == "0" ]]; then
        run_capture "c02-${name}" 0 "$BORIS" --html --input "$input" --html-dir "$output" --html-layout "$LAYOUT" --quiet
        assert_empty "$OUT/logs/c02-${name}.stdout"
        assert_empty "$OUT/logs/c02-${name}.stderr"
        assert_file "$output/index.html"
        assert_cmp "$C02/$expected_html" "$output/index.html"
        run_capture "c02-${name}-repeat" 0 "$BORIS" --html --input "$input" --html-dir "$OUT/outputs/${name}-repeat" --html-layout "$LAYOUT" --quiet
        assert_empty "$OUT/logs/c02-${name}-repeat.stdout"
        assert_empty "$OUT/logs/c02-${name}-repeat.stderr"
        assert_tree_equal "$output" "$OUT/outputs/${name}-repeat"
        pass "c02-${name}: generated ${depth}-level chain, exit 0, golden, repeat tree"
    else
        run_capture "c02-${name}" 1 "$BORIS" --html --input "$input" --html-dir "$output" --html-layout "$LAYOUT"
        assert_empty "$OUT/logs/c02-${name}.stdout"
        assert_diag "$C02/$expected_stderr" "$OUT/logs/c02-${name}.stderr"
        assert_no_html_target "$output"
        pass "c02-${name}: generated ${depth}-level chain, exit 1, exact diagnostic, no final HTML target"
    fi
done <"$C02/depth-cases.psv"

note "C03 sitemap"
SITE_URL='https://docs.example/docs&guides/'
SITEMAP_GOLDEN="$C03/expected/meta/discovery.xml"
for variant in trailing no-trailing; do
    url="$SITE_URL"
    [[ "$variant" == "no-trailing" ]] && url="${SITE_URL%/}"
    output="$OUT/outputs/c03-${variant}"
    run_capture "c03-${variant}" 0 "$BORIS" --html --input "$C03/content" --html-dir "$output" --html-layout "$C03/layout.html" --sitemap-path meta/discovery.xml --site-url "$url" --quiet
    assert_empty "$OUT/logs/c03-${variant}.stdout"
    assert_empty "$OUT/logs/c03-${variant}.stderr"
    assert_cmp "$SITEMAP_GOLDEN" "$output/meta/discovery.xml"
done
assert_tree_equal "$OUT/outputs/c03-trailing" "$OUT/outputs/c03-no-trailing"
run_capture "c03-trailing-repeat" 0 "$BORIS" --html --input "$C03/content" --html-dir "$OUT/outputs/c03-trailing-repeat" --html-layout "$C03/layout.html" --sitemap-path meta/discovery.xml --site-url "$SITE_URL" --quiet
assert_empty "$OUT/logs/c03-trailing-repeat.stdout"
assert_empty "$OUT/logs/c03-trailing-repeat.stderr"
assert_tree_equal "$OUT/outputs/c03-trailing" "$OUT/outputs/c03-trailing-repeat"
pass "c03: sitemap golden, slash normalization, and repeat trees"

for invalid in relative mailto query malformed-authority; do
    case "$invalid" in
        relative) site_url='relative' ;;
        mailto) site_url='mailto:docs@example.test' ;;
        query) site_url='https://docs.example/docs?query=1' ;;
        malformed-authority) site_url='https:///docs' ;;
    esac
    output="$OUT/outputs/c03-invalid-${invalid}"
    run_capture "c03-invalid-${invalid}" 2 "$BORIS" --html --input "$C03/content" --html-dir "$output" --html-layout "$C03/layout.html" --sitemap --site-url "$site_url"
    assert_diag "$C03/expected/invalid-site-url.stderr" "$OUT/logs/c03-invalid-${invalid}.stderr"
    assert_absent "$output"
done
pass "c03: invalid URL shapes exit 2 without publication"

note "C04 RSS"
RSS_SITE_URL='https://example.test/docs&guides'
RSS_TITLE='Docs & <Feed> "News"'
RSS_DESCRIPTION='Recent & <updates> "quotes"'
for limit in 2 3 4; do
    output="$OUT/outputs/c04-feed-${limit}.xml"
    run_capture "c04-feed-${limit}" 0 "$BORIS" --rss --input "$C04/content" --rss-path "$output" --site-url "$RSS_SITE_URL" --rss-title "$RSS_TITLE" --rss-description "$RSS_DESCRIPTION" --rss-limit "$limit" --quiet
    assert_empty "$OUT/logs/c04-feed-${limit}.stdout"
    assert_empty "$OUT/logs/c04-feed-${limit}.stderr"
    assert_cmp "$C04/expected/feed-limit-${limit}.xml" "$output"
done
run_capture "c04-feed-3-repeat" 0 "$BORIS" --rss --input "$C04/content" --rss-path "$OUT/outputs/c04-feed-3-repeat.xml" --site-url "$RSS_SITE_URL" --rss-title "$RSS_TITLE" --rss-description "$RSS_DESCRIPTION" --rss-limit 3 --quiet
assert_empty "$OUT/logs/c04-feed-3-repeat.stdout"
assert_empty "$OUT/logs/c04-feed-3-repeat.stderr"
assert_cmp "$OUT/outputs/c04-feed-3.xml" "$OUT/outputs/c04-feed-3-repeat.xml"
pass "c04: feed limit goldens, escaping, and repeat feed"

missing_output="$OUT/outputs/c04-missing-summary.xml"
run_capture "c04-missing-summary" 1 "$BORIS" --rss --input "$C04/cases/missing-summary/content" --rss-path "$missing_output" --site-url 'https://example.test' --rss-title Docs --rss-description Updates
assert_empty "$OUT/logs/c04-missing-summary.stdout"
assert_diag "$C04/cases/missing-summary/expected/stderr.txt" "$OUT/logs/c04-missing-summary.stderr"
assert_absent "$missing_output"
pass "c04-missing-summary: exit 1, exact diagnostic, no feed"

for limit in 0 501; do
    output="$OUT/outputs/c04-invalid-limit-${limit}.xml"
    run_capture "c04-invalid-limit-${limit}" 2 "$BORIS" --rss --input "$C04/content" --rss-path "$output" --site-url 'https://example.test' --rss-title Docs --rss-description Updates --rss-limit "$limit"
    assert_diag "$C04/expected/invalid-value.stderr" "$OUT/logs/c04-invalid-limit-${limit}.stderr"
    assert_absent "$output"
done
for missing in site title description; do
    output="$OUT/outputs/c04-missing-${missing}.xml"
    args=(--rss --input "$C04/content" --rss-path "$output" --site-url 'https://example.test' --rss-title Docs --rss-description Updates)
    case "$missing" in
        site) args=(--rss --input "$C04/content" --rss-path "$output" --rss-title Docs --rss-description Updates) ;;
        title) args=(--rss --input "$C04/content" --rss-path "$output" --site-url 'https://example.test' --rss-description Updates) ;;
        description) args=(--rss --input "$C04/content" --rss-path "$output" --site-url 'https://example.test' --rss-title Docs) ;;
    esac
    run_capture "c04-missing-${missing}" 2 "$BORIS" "${args[@]}"
    assert_diag "$C04/expected/missing-value.stderr" "$OUT/logs/c04-missing-${missing}.stderr"
    assert_absent "$output"
done
pass "c04: invalid limits and missing required settings exit 2"

note "C08 parser and Unicode"
valid_out="$OUT/outputs/c08-valid"
run_capture c08-valid 0 "$BORIS" --no-rag --input "$C08/content" --out "$valid_out"
assert_empty "$OUT/logs/c08-valid.stdout"
assert_nonempty "$OUT/logs/c08-valid.stderr"
assert_cmp "$C08/expected/graph.json" "$valid_out/graph.json"
assert_file "$valid_out/manifest.json"
assert_file "$valid_out/build-report.json"
run_capture c08-valid-repeat 0 "$BORIS" --no-rag --input "$C08/content" --out "$OUT/outputs/c08-valid-repeat"
assert_cmp "$valid_out/graph.json" "$OUT/outputs/c08-valid-repeat/graph.json"
assert_cmp "$valid_out/manifest.json" "$OUT/outputs/c08-valid-repeat/manifest.json"
pass "c08-valid: Unicode IR golden and repeat graph/manifest"

for invalid in malformed-unicode bom; do
    output="$OUT/outputs/c08-${invalid}"
    run_capture "c08-${invalid}" 1 "$BORIS" --no-rag --input "$C08/cases/${invalid}/content" --out "$output"
    assert_empty "$OUT/logs/c08-${invalid}.stdout"
    assert_diag "$C08/cases/${invalid}/expected/stderr.txt" "$OUT/logs/c08-${invalid}.stderr"
    assert_failed_ir_state "$output"
done
invalid_utf8_out="$OUT/outputs/c08-invalid-utf8"
run_capture c08-invalid-utf8 1 "$BORIS" --no-rag --input fixtures/content/invalid --out "$invalid_utf8_out"
assert_empty "$OUT/logs/c08-invalid-utf8.stdout"
assert_diag "$C08/expected/invalid-utf8.stderr" "$OUT/logs/c08-invalid-utf8.stderr"
assert_failed_ir_state "$invalid_utf8_out"
pass "c08-invalid: BOM, malformed Unicode, and invalid UTF-8 fail closed"

note "C01 Textile compatibility"
c01_ok() {
    local name="$1"
    shift
    run_capture "c01-${name}" 0 "$BORIS" --textile --html --input "$C01/content" --html-dir "$OUT/outputs/c01-${name}" --html-layout "$C01/layout.html" --quiet "$@"
    assert_empty "$OUT/logs/c01-${name}.stdout"
    assert_empty "$OUT/logs/c01-${name}.stderr"
    assert_file "$OUT/outputs/c01-${name}/index.html"
    assert_file "$OUT/outputs/c01-${name}/guides/satellite.html"
}
c01_ok valid
assert_cmp "$C01/expected/index.html" "$OUT/outputs/c01-valid/index.html"
assert_cmp "$C01/expected/guides-satellite.html" "$OUT/outputs/c01-valid/guides/satellite.html"
c01_ok valid-jobs4 --jobs 4
assert_page_equal "$OUT/outputs/c01-valid" "$OUT/outputs/c01-valid-jobs4"
c01_ok valid-incr --incremental
assert_page_equal "$OUT/outputs/c01-valid" "$OUT/outputs/c01-valid-incr"
c01_ok valid-incr-jobs4 --incremental --jobs 4
assert_page_equal "$OUT/outputs/c01-valid-incr" "$OUT/outputs/c01-valid-incr-jobs4"
pass "c01-valid: goldens, jobs 1==4, clean==incremental"

for name in frontmatter malformed-delimiter malformed-incomplete-link unsafe-link \
    unsupported-attributes unsupported-blockcode unsupported-notextile unsupported-table \
    include-in-textile mixed mode-markdown-flag; do
    out="$OUT/outputs/c01-${name}"
    run_capture "c01-${name}" 1 "$BORIS" --textile --html --input "$C01/cases/${name}/content" --html-dir "$out" --html-layout "$C01/layout.html"
    assert_empty "$OUT/logs/c01-${name}.stdout"
    assert_diag "$C01/cases/${name}/expected/stderr.txt" "$OUT/logs/c01-${name}.stderr"
    assert_no_html_target "$out"
    pass "c01-${name}: exit 1, exact diagnostic, no final HTML target"
done
out="$OUT/outputs/c01-mode-textile-noflag"
run_capture c01-mode-textile-noflag 1 "$BORIS" --html --input "$C01/cases/mode-textile-noflag/content" --html-dir "$out" --html-layout "$C01/layout.html"
assert_empty "$OUT/logs/c01-mode-textile-noflag.stdout"
assert_diag "$C01/cases/mode-textile-noflag/expected/stderr.txt" "$OUT/logs/c01-mode-textile-noflag.stderr"
assert_no_html_target "$out"
pass "c01-mode-textile-noflag: exit 1, exact diagnostic, no final HTML target"

note "C05 layout precedence"
run_capture c05-explicit 0 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-explicit" --html-layout "$C05/layouts/exact.html" --quiet
assert_contains "C05-EXACT" "$OUT/outputs/c05-explicit/index.html"
run_capture c05-rule-id 0 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-rule-id" --html-layout "$C05/layouts/global.html" --layout-rule default "id:reference/config" "$C05/layouts/target.html" --quiet
assert_contains "C05-TARGET" "$OUT/outputs/c05-rule-id/reference/config.html"
assert_contains "C05-GLOBAL" "$OUT/outputs/c05-rule-id/index.html"
run_capture c05-rule-glob 0 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-rule-glob" --html-layout "$C05/layouts/global.html" --layout-rule default "glob:guides/*" "$C05/layouts/glob.html" --layout-rule default "glob:reference/deep/*" "$C05/layouts/deep.html" --quiet
assert_contains "C05-GLOB" "$OUT/outputs/c05-rule-glob/guides/g1.html"
assert_contains "C05-DEEP" "$OUT/outputs/c05-rule-glob/reference/deep/d.html"
assert_contains "C05-GLOBAL" "$OUT/outputs/c05-rule-glob/reference/config.html"
run_capture c05-rule-role 0 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-rule-role" --html-layout "$C05/layouts/global.html" --layout-rule default "role:trunk" "$C05/layouts/role.html" --quiet
assert_contains "C05-ROLE" "$OUT/outputs/c05-rule-role/index.html"
assert_contains "C05-GLOBAL" "$OUT/outputs/c05-rule-role/reference/config.html"
run_capture c05-theme 0 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-theme" --theme "$C05/theme" --quiet
assert_contains "C05-THEME" "$OUT/outputs/c05-theme/index.html"
run_capture c05-multi 0 "$BORIS" --html --input "$C05/content" --target one="$OUT/outputs/c05-multi-one" --target two="$OUT/outputs/c05-multi-two" --target-layout one="$C05/layouts/exact.html" --target-layout two="$C05/layouts/global.html" --quiet
assert_contains "C05-EXACT" "$OUT/outputs/c05-multi-one/index.html"
assert_contains "C05-GLOBAL" "$OUT/outputs/c05-multi-two/index.html"
pass "c05-success: explicit, rule id/glob/role, theme, multi-target isolation"

run_capture c05-missing-layout 3 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-missing-layout" --html-layout "$C05/layouts/nope.html"
assert_empty "$OUT/logs/c05-missing-layout.stdout"
assert_diag "$C05/expected/missing-layout.stderr" "$OUT/logs/c05-missing-layout.stderr"
assert_no_html_target "$OUT/outputs/c05-missing-layout"
run_capture c05-missing-marker 1 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-missing-marker" --html-layout "$C05/layouts/nomarker.html"
assert_empty "$OUT/logs/c05-missing-marker.stdout"
assert_diag "$C05/expected/missing-marker.stderr" "$OUT/logs/c05-missing-marker.stderr"
assert_no_html_target "$OUT/outputs/c05-missing-marker"
run_capture c05-duplicate-marker 1 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-duplicate-marker" --html-layout "$C05/layouts/dupmarker.html"
assert_empty "$OUT/logs/c05-duplicate-marker.stdout"
assert_diag "$C05/expected/duplicate-marker.stderr" "$OUT/logs/c05-duplicate-marker.stderr"
assert_no_html_target "$OUT/outputs/c05-duplicate-marker"
run_capture c05-ambiguous-glob 2 "$BORIS" --html --input "$C05/content" --html-dir "$OUT/outputs/c05-ambiguous-glob" --html-layout "$C05/layouts/global.html" --layout-rule default "glob:reference/*" "$C05/layouts/glob.html" --layout-rule default "glob:*/config" "$C05/layouts/target.html"
assert_empty "$OUT/logs/c05-ambiguous-glob.stdout"
head -2 "$OUT/logs/c05-ambiguous-glob.stderr" >"$OUT/logs/c05-ambiguous-glob.head2"
assert_diag "$C05/expected/ambiguous-glob.stderr" "$OUT/logs/c05-ambiguous-glob.head2"
assert_no_html_target "$OUT/outputs/c05-ambiguous-glob"
pass "c05-failures: missing layout 3, marker failures 1, ambiguous glob 2"

# C05 incremental: one reused output target with --incremental, using a real
# competing-rule relationship (exact-id winner over a matching glob) so a
# losing-layout edit is a genuine precedence case, not an unrelated page.
C05_INC="$OUT/generated/c05-inc"
rm -rf "$C05_INC"
mkdir -p "$C05_INC/layouts"
cp "$C05/layouts/global.html" "$C05_INC/layouts/global.html"
cp "$C05/layouts/target.html" "$C05_INC/layouts/target.html"
cp "$C05/layouts/glob.html" "$C05_INC/layouts/glob.html"
C05_INC_OUT="$OUT/outputs/c05-inc"
C05_INC_ARGS=(--html --input "$C05/content" --html-dir "$C05_INC_OUT" --html-layout "$C05_INC/layouts/global.html" --layout-rule default "id:reference/config" "$C05_INC/layouts/target.html" --layout-rule default "glob:reference/*" "$C05_INC/layouts/glob.html" --quiet --incremental)
# Step 1: clean baseline — incremental first publication into one target.
run_capture c05-incr-base 0 "$BORIS" "${C05_INC_ARGS[@]}"
assert_empty "$OUT/logs/c05-incr-base.stdout"
assert_empty "$OUT/logs/c05-incr-base.stderr"
assert_contains "C05-TARGET" "$C05_INC_OUT/reference/config.html"
assert_contains "C05-GLOBAL" "$C05_INC_OUT/index.html"
assert_file "$C05_INC_OUT/.boris-cache/manifest.json"
# Steps 2–4: modify the WINNING layout at the same configured path, rebuild the
# same target incrementally; the affected page changes, an unaffected page
# stays byte-identical.
cp "$C05_INC_OUT/index.html" "$OUT/logs/c05-incr-index-v1.html"
sed 's/C05-TARGET/C05-TARGET-V2/' "$C05_INC/layouts/target.html" >"$C05_INC/layouts/target.next"
mv "$C05_INC/layouts/target.next" "$C05_INC/layouts/target.html"
# Rebuild reuses the prior target/cache: the baseline manifest must still exist.
assert_file "$C05_INC_OUT/.boris-cache/manifest.json"
run_capture c05-incr-win 0 "$BORIS" "${C05_INC_ARGS[@]}"
assert_empty "$OUT/logs/c05-incr-win.stdout"
assert_empty "$OUT/logs/c05-incr-win.stderr"
assert_contains "C05-TARGET-V2" "$C05_INC_OUT/reference/config.html"
assert_cmp "$OUT/logs/c05-incr-index-v1.html" "$C05_INC_OUT/index.html"
cp "$C05_INC_OUT/reference/config.html" "$OUT/logs/c05-incr-config-v2.html"
# Steps 5–8: modify only the LOSING layout (glob) at the same configured path;
# the higher-precedence exact-id winner's page stays byte-identical.
sed 's/C05-GLOB/C05-GLOB-V3/' "$C05_INC/layouts/glob.html" >"$C05_INC/layouts/glob.next"
mv "$C05_INC/layouts/glob.next" "$C05_INC/layouts/glob.html"
# Same reused target: the winning-rebuild manifest must still exist.
assert_file "$C05_INC_OUT/.boris-cache/manifest.json"
run_capture c05-incr-lose 0 "$BORIS" "${C05_INC_ARGS[@]}"
assert_empty "$OUT/logs/c05-incr-lose.stdout"
assert_empty "$OUT/logs/c05-incr-lose.stderr"
assert_cmp "$OUT/logs/c05-incr-config-v2.html" "$C05_INC_OUT/reference/config.html"
assert_cmp "$OUT/logs/c05-incr-index-v1.html" "$C05_INC_OUT/index.html"
pass "c05-incr: same target; winning layout edit propagates, losing layout edit has no effect"

note "C06 cache and watch failure paths"
C06_WS="$OUT/generated/c06-ws"
c06_reset() {
    rm -rf "$C06_WS"
    mkdir -p "$C06_WS"
    cp -r "$C06/content" "$C06_WS/content"
    cp -r "$C06/theme" "$C06_WS/theme"
}
# Incremental scenarios reuse ONE dedicated output directory: the first run is
# an incremental first publication (renders everything, writes the manifest),
# and every edit is an --incremental rebuild into that same directory.
c06_incr() {
    local name="$1"
    shift
    run_capture "c06-${name}-base" 0 "$BORIS" --html --input "$C06_WS/content" --html-dir "$OUT/outputs/c06-${name}" --quiet --incremental "$@"
    assert_empty "$OUT/logs/c06-${name}-base.stdout"
    assert_empty "$OUT/logs/c06-${name}-base.stderr"
}
c06_incr_rebuild() {
    local name="$1"
    shift
    # Rebuild must reuse the prior target/cache: the manifest written by the
    # incremental baseline must still exist in the same output directory.
    assert_file "$OUT/outputs/c06-${name}/.boris-cache/manifest.json"
    run_capture "c06-${name}-reb" 0 "$BORIS" --html --input "$C06_WS/content" --html-dir "$OUT/outputs/c06-${name}" --quiet --incremental "$@"
    assert_empty "$OUT/logs/c06-${name}-reb.stdout"
    assert_empty "$OUT/logs/c06-${name}-reb.stderr"
}

# No-op reuse: baseline, snapshot payload, two unchanged incremental rebuilds.
c06_reset
c06_incr noop --html-layout "$C06/layout.html"
assert_contains "Fragment v1" "$OUT/outputs/c06-noop/index.html"
assert_file "$OUT/outputs/c06-noop/.boris-cache/manifest.json"
cp -R "$OUT/outputs/c06-noop" "$OUT/snapshots/c06-noop-base"
c06_incr_rebuild noop --html-layout "$C06/layout.html"
assert_page_equal "$OUT/snapshots/c06-noop-base" "$OUT/outputs/c06-noop"
cp "$OUT/outputs/c06-noop/.boris-cache/manifest.json" "$OUT/logs/c06-noop-manifest-1.json"
c06_incr_rebuild noop --html-layout "$C06/layout.html"
cp "$OUT/outputs/c06-noop/.boris-cache/manifest.json" "$OUT/logs/c06-noop-manifest-2.json"
assert_cmp "$OUT/logs/c06-noop-manifest-1.json" "$OUT/logs/c06-noop-manifest-2.json"
assert_page_equal "$OUT/snapshots/c06-noop-base" "$OUT/outputs/c06-noop"
pass "c06-noop: one reused target; unchanged incremental rebuilds keep payload and manifest byte-identical"

# Source edit: affected page changes, unaffected sibling byte-identical.
c06_reset
c06_incr source-edit --html-layout "$C06/layout.html"
cp "$OUT/outputs/c06-source-edit/index.html" "$OUT/logs/c06-source-edit-index-v1.html"
printf -- '---\ntitle: Guide\nparent: index\n---\nGuide body v2\n' >"$C06_WS/content/guides/g1.md"
c06_incr_rebuild source-edit --html-layout "$C06/layout.html"
assert_contains "Guide body v2" "$OUT/outputs/c06-source-edit/guides/g1.html"
assert_cmp "$OUT/logs/c06-source-edit-index-v1.html" "$OUT/outputs/c06-source-edit/index.html"
pass "c06-source-edit: one reused target; edited page changes, sibling byte-identical"

# Source deletion: incremental baseline leaves the manifest, so the rebuild
# prunes the stale HTML (prior-manifest path).
c06_reset
c06_incr source-delete --html-layout "$C06/layout.html"
assert_file "$OUT/outputs/c06-source-delete/guides/g1.html"
rm "$C06_WS/content/guides/g1.md"
c06_incr_rebuild source-delete --html-layout "$C06/layout.html"
assert_absent "$OUT/outputs/c06-source-delete/guides/g1.html"
pass "c06-source-delete: one reused target; deleted page's stale HTML removed"

# Include edit: dependent page changes.
c06_reset
c06_incr include-edit --html-layout "$C06/layout.html"
assert_contains "Fragment v1" "$OUT/outputs/c06-include-edit/index.html"
printf 'Fragment v2\n' >"$C06_WS/content/includes/frag.md"
c06_incr_rebuild include-edit --html-layout "$C06/layout.html"
assert_contains "Fragment v2" "$OUT/outputs/c06-include-edit/index.html"
pass "c06-include-edit: one reused target; fragment edit propagates to dependent page"

# Theme asset edit: published asset changes.
c06_reset
c06_incr theme --theme "$C06_WS/theme"
cp "$OUT/outputs/c06-theme/assets/theme.css" "$OUT/logs/c06-theme-v1.css"
printf 'body{color:red}\n' >>"$C06_WS/theme/assets/theme.css"
c06_incr_rebuild theme --theme "$C06_WS/theme"
cmp -s "$OUT/logs/c06-theme-v1.css" "$OUT/outputs/c06-theme/assets/theme.css" && fail "c06-theme: theme asset edit did not change output"
pass "c06-theme: one reused target; theme asset edit propagates"

# Content-local asset edit: published asset changes.
c06_reset
c06_incr content-asset --html-layout "$C06/layout.html"
cp "$OUT/outputs/c06-content-asset/index.assets/style.css" "$OUT/logs/c06-content-asset-v1.css"
printf 'body{color:green}\n' >>"$C06_WS/content/index.assets/style.css"
c06_incr_rebuild content-asset --html-layout "$C06/layout.html"
cmp -s "$OUT/logs/c06-content-asset-v1.css" "$OUT/outputs/c06-content-asset/index.assets/style.css" && fail "c06-content-asset: asset edit did not change output"
pass "c06-content-asset: one reused target; content-local asset edit propagates"

# Sitemap invalidation: draft edit replaces the sitemap without the page.
c06_reset
c06_incr sitemap --html-layout "$C06/layout.html" --sitemap-path sitemap.xml --site-url https://example.test
assert_contains "guides/g1.html" "$OUT/outputs/c06-sitemap/sitemap.xml"
printf -- '---\ntitle: Guide\nparent: index\nstatus: draft\n---\nGuide body\n' >"$C06_WS/content/guides/g1.md"
c06_incr_rebuild sitemap --html-layout "$C06/layout.html" --sitemap-path sitemap.xml --site-url https://example.test
if grep -F "guides/g1.html" "$OUT/outputs/c06-sitemap/sitemap.xml" >/dev/null; then
    fail "c06-sitemap: draft page still present in sitemap"
fi
assert_file "$OUT/outputs/c06-sitemap/sitemap.xml"
pass "c06-sitemap: one reused target; draft edit replaces sitemap without the page"

# Rendered-search invalidation: body edit changes the search artifact.
c06_reset
c06_incr search --html-layout "$C06/layout.html"
cp "$OUT/outputs/c06-search/_boris/search/search-index.json" "$OUT/logs/c06-search-before.json"
printf -- '---\ntitle: Index\n---\nIntro v2 {{include includes/frag.md}}\n' >"$C06_WS/content/index.md"
c06_incr_rebuild search --html-layout "$C06/layout.html"
cmp -s "$OUT/logs/c06-search-before.json" "$OUT/outputs/c06-search/_boris/search/search-index.json" && fail "c06-search: body edit did not change search index"
pass "c06-search: one reused target; body edit invalidates rendered-search artifact"

# Failure-only cases stay on isolated fresh targets (not cache-invalidation
# evidence): missing include, failed parse, duplicate layout marker.
c06_reset
c06_incr include-missing-base --html-layout "$C06/layout.html"
rm "$C06_WS/content/includes/frag.md"
run_capture c06-include-missing 1 "$BORIS" --html --input "$C06_WS/content" --html-dir "$OUT/outputs/c06-include-missing" --html-layout "$C06/layout.html"
assert_empty "$OUT/logs/c06-include-missing.stdout"
assert_diag "$C06/expected/include-missing.stderr" "$OUT/logs/c06-include-missing.stderr"
assert_no_html_target "$OUT/outputs/c06-include-missing"
c06_reset
c06_incr parse-failed-base --html-layout "$C06/layout.html"
printf -- '---\ntitle: Bad\nbadkey: x\n---\nBody\n' >"$C06_WS/content/bad.md"
run_capture c06-parse-failed 1 "$BORIS" --html --input "$C06_WS/content" --html-dir "$OUT/outputs/c06-parse-failed" --html-layout "$C06/layout.html"
assert_empty "$OUT/logs/c06-parse-failed.stdout"
assert_diag "$C06/expected/parse-failed.stderr" "$OUT/logs/c06-parse-failed.stderr"
assert_no_html_target "$OUT/outputs/c06-parse-failed"
run_capture c06-layout-dup 1 "$BORIS" --html --input "$C06/content" --html-dir "$OUT/outputs/c06-layout-dup" --html-layout "$C06/dup.html"
assert_empty "$OUT/logs/c06-layout-dup.stdout"
assert_diag "$C06/expected/layout-dup-marker.stderr" "$OUT/logs/c06-layout-dup.stderr"
assert_no_html_target "$OUT/outputs/c06-layout-dup"
pass "c06-failures: missing include, failed parse, duplicate layout marker fail closed on isolated targets"

c06_watch_ws="$C06_WS-watch"
rm -rf "$c06_watch_ws"
mkdir -p "$c06_watch_ws/layouts"
cp -r "$C06/content" "$c06_watch_ws/content"
cp "$C06/layout.html" "$c06_watch_ws/layouts/main.html"
start_watch() {
    local name="$1"
    ( cd "$c06_watch_ws" && exec "$BORIS_ABS" watch --html --input content --html-dir site --html-layout layouts/main.html >"$ROOT/$OUT/logs/${name}.log" 2>&1 ) &
    local pid=$!
    WATCH_PIDS+=("$pid")
    printf '%s\n' "$pid" >"$OUT/logs/${name}.pid"
}
start_watch c06-watch-a
wait_for_grep "$OUT/logs/c06-watch-a.log" "initial build succeeded" 100 || fail "c06-watch: initial build missing"
assert_contains "Fragment v1" "$c06_watch_ws/site/index.html"
printf -- '---\ntitle: Guide\nparent: index\n---\nGuide watch v2\n' >"$c06_watch_ws/content/guides/g1.md"
wait_for_grep "$c06_watch_ws/site/guides/g1.html" "Guide watch v2" 100 || fail "c06-watch: observed rebuild missing"
pid=$(cat "$OUT/logs/c06-watch-a.pid")
kill -TERM "$pid" 2>/dev/null || true
if wait "$pid"; then
    pass "c06-watch: startup, observed rebuild, clean SIGTERM exit 0"
else
    rc=$?
    fail "c06-watch: SIGTERM exit ${rc}, expected 0"
fi

rm -rf "$c06_watch_ws/site"
start_watch c06-watch-fail
wait_for_grep "$OUT/logs/c06-watch-fail.log" "initial build succeeded" 100 || fail "c06-watch-fail: initial build missing"
assert_contains "Fragment v1" "$c06_watch_ws/site/index.html"
# Save the exact bytes of the currently valid published HTML.
cp "$c06_watch_ws/site/index.html" "$OUT/logs/c06-watch-fail-index-v1.html"
pid=$(cat "$OUT/logs/c06-watch-fail.pid")
# Delete the referenced include; the rebuild must fail recoverably and the
# watcher must keep running so the author can correct the source.
rm "$c06_watch_ws/content/includes/frag.md"
wait_for_grep "$OUT/logs/c06-watch-fail.log" "error: rebuild failed: IncludeFailed. Waiting for correction" 100 || fail "c06-watch-fail: recoverable rebuild-failure diagnostic missing"
# Prove the same watcher process is still alive after the failed rebuild.
kill -0 "$pid" 2>/dev/null || fail "c06-watch-fail: watcher exited after recoverable failed include rebuild"
# Prove the previously valid published HTML remains byte-identical.
cmp -s "$OUT/logs/c06-watch-fail-index-v1.html" "$c06_watch_ws/site/index.html" || fail "c06-watch-fail: prior valid output changed during failed rebuild"
# Restore the include with visibly changed content; the same watcher session
# must publish the corrected output (no process restart).
printf 'Fragment v2\n' >"$c06_watch_ws/content/includes/frag.md"
wait_for_grep "$c06_watch_ws/site/index.html" "Fragment v2" 100 || fail "c06-watch-fail: same-session corrected rebuild missing"
kill -TERM "$pid" 2>/dev/null || true
if wait "$pid"; then
    pass "c06-watch-fail: failed include rebuild keeps watcher alive, preserves output, recovers in-session, clean SIGTERM exit 0"
else
    rc=$?
    fail "c06-watch-fail: SIGTERM exit ${rc}, expected 0"
fi

note "C07 asset collisions and SVG policy"
c07_mk() {
    local gen="$1"
    rm -rf "$gen"
    mkdir -p "$gen/content/guides/intro.assets"
    cp "$C07/content/guides/intro.md" "$gen/content/guides/intro.md"
}
for spec in \
    "svg-script|<svg xmlns=\"http://www.w3.org/2000/svg\"><script>alert(1)</script></svg>" \
    "svg-event-handler|<svg xmlns=\"http://www.w3.org/2000/svg\" onload=\"alert(1)\"><rect width=\"1\" height=\"1\"/></svg>" \
    "svg-javascript-url|<svg xmlns=\"http://www.w3.org/2000/svg\"><a href=\"javascript:alert(1)\"><text>x</text></a></svg>" \
    "svg-foreignobject|<svg xmlns=\"http://www.w3.org/2000/svg\"><foreignObject><div>hi</div></foreignObject></svg>" \
    "svg-iframe|<svg xmlns=\"http://www.w3.org/2000/svg\"><iframe src=\"https://evil.test\"/></svg>" \
    "svg-object|<svg xmlns=\"http://www.w3.org/2000/svg\"><object data=\"https://evil.test\"/></svg>" \
    "svg-doctype|<!DOCTYPE svg PUBLIC \"-//W3C//DTD SVG 1.1//EN\" \"http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd\"><svg xmlns=\"http://www.w3.org/2000/svg\"><text>x</text></svg>" \
    "svg-style-import|<svg xmlns=\"http://www.w3.org/2000/svg\"><style>@import url(\"https://evil.test/x.css\");</style><rect width=\"1\" height=\"1\"/></svg>" \
    "svg-animate-onload|<svg xmlns=\"http://www.w3.org/2000/svg\"><animate attributeName=\"onload\" values=\"alert(1)\" dur=\"1s\"/></svg>"; do
    name="${spec%%|*}"
    body="${spec#*|}"
    gen="$OUT/generated/c07-${name}"
    c07_mk "$gen"
    printf '%s\n' "$body" >"$gen/content/guides/intro.assets/t.svg"
    out="$OUT/outputs/c07-${name}"
    run_capture "c07-${name}" 1 "$BORIS" --html --input "$gen/content" --html-dir "$out" --html-layout "$C07/layout.html"
    assert_empty "$OUT/logs/c07-${name}.stdout"
    # The retained snapshot includes the per-target attribution line
    # (`target 'default' compilation failed: AssetUnsafeSvg`) that
    # compileHtmlSiteMulti prints for errors outside its suppression list;
    # keep the two lines coupled deliberately.
    assert_diag "$C07/expected/${name}.stderr" "$OUT/logs/c07-${name}.stderr"
    # Active-SVG rejection is a content failure: the generic I/O summary line
    # must never appear on the content-class exit path.
    if grep -F "I/O or a system error" "$OUT/logs/c07-${name}.stderr" >/dev/null; then
        fail "c07-${name}: I/O summary line present for a content-class EASSET failure"
    fi
    assert_no_html_target "$out"
    # Rejected SVG must not be copied or inventoried.
    assert_absent "$out/_boris/proof/artifacts.json"
    pass "c07-${name}: exit 1, exact EASSET diagnostic, no I/O summary, rejected SVG never emitted or inventoried"
done

# Multi-target: content with an unsafe SVG fails every target that encounters
# it; the aggregate must remain content class (exit 1) and must never be
# misclassified into the multi-target I/O summary line.
gen="$OUT/generated/c07-svg-multi"
c07_mk "$gen"
printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg"><script>alert(1)</script></svg>' >"$gen/content/guides/intro.assets/t.svg"
out_a="$OUT/outputs/c07-svg-multi-a"
out_b="$OUT/outputs/c07-svg-multi-b"
run_capture c07-svg-multi 1 "$BORIS" --html --input "$gen/content" --target alpha="$out_a" --target beta="$out_b" --html-layout "$C07/layout.html"
assert_empty "$OUT/logs/c07-svg-multi.stdout"
assert_contains "content-local SVG contains active content: active SVG <script> element" "$OUT/logs/c07-svg-multi.stderr"
if grep -F "one or more HTML targets failed due to I/O or a system error" "$OUT/logs/c07-svg-multi.stderr" >/dev/null; then
    fail "c07-svg-multi: unsafe SVG misclassified as system I/O"
fi
assert_no_html_target "$out_a"
assert_no_html_target "$out_b"
assert_absent "$out_a/_boris/proof/artifacts.json"
assert_absent "$out_b/_boris/proof/artifacts.json"
pass "c07-svg-multi: multi-target unsafe SVG exits content 1 with no I/O summary"

gen="$OUT/generated/c07-valid"
c07_mk "$gen"
printf '<svg xmlns="http://www.w3.org/2000/svg"><text>&#x1F42F; café 東京</text></svg>\n' >"$gen/content/guides/intro.assets/logo.svg"
run_capture c07-valid 0 "$BORIS" --html --input "$gen/content" --html-dir "$OUT/outputs/c07-valid" --html-layout "$C07/layout.html" --quiet
assert_cmp "$gen/content/guides/intro.assets/logo.svg" "$OUT/outputs/c07-valid/guides/intro.assets/logo.svg"
assert_contains '"guides/intro.assets/logo.svg"' "$OUT/outputs/c07-valid/_boris/proof/artifacts.json"
run_capture c07-valid-jobs4 0 "$BORIS" --html --input "$gen/content" --html-dir "$OUT/outputs/c07-valid-jobs4" --html-layout "$C07/layout.html" --quiet --jobs 4
assert_page_equal "$OUT/outputs/c07-valid" "$OUT/outputs/c07-valid-jobs4"
run_capture c07-valid-incr 0 "$BORIS" --html --input "$gen/content" --html-dir "$OUT/outputs/c07-valid-incr" --html-layout "$C07/layout.html" --quiet --incremental
assert_page_equal "$OUT/outputs/c07-valid" "$OUT/outputs/c07-valid-incr"
pass "c07-valid: inert Unicode SVG accepted, copied, inventoried; jobs and incremental equal"

gen="$OUT/generated/c07-theme-page"
rm -rf "$gen"
mkdir -p "$gen/content/guides" "$gen/content/assets" "$gen/theme/layouts" "$gen/theme/assets"
cp "$C07/content/guides/intro.md" "$gen/content/guides/intro.md"
printf -- '---\ntitle: Asset Page\n---\nAsset body\n' >"$gen/content/assets/index.md"
printf '<html><body>{{content}}</body></html>\n' >"$gen/theme/layouts/main.html"
printf 'THEME PAGE\n' >"$gen/theme/assets/index.html"
run_capture c07-theme-page 1 "$BORIS" --html --input "$gen/content" --html-dir "$OUT/outputs/c07-theme-page" --theme "$gen/theme"
assert_empty "$OUT/logs/c07-theme-page.stdout"
assert_diag "$C07/expected/theme-page-collision.stderr" "$OUT/logs/c07-theme-page.stderr"
assert_no_html_target "$OUT/outputs/c07-theme-page"
pass "c07-theme-page: page output vs theme asset collision fails closed"

gen="$OUT/generated/c07-symlink"
c07_mk "$gen"
ln -s /etc/hosts "$gen/content/guides/intro.assets/link.svg" 2>/dev/null || true
if [[ -L "$gen/content/guides/intro.assets/link.svg" ]]; then
    run_capture c07-symlink 1 "$BORIS" --html --input "$gen/content" --html-dir "$OUT/outputs/c07-symlink" --html-layout "$C07/layout.html"
    assert_empty "$OUT/logs/c07-symlink.stdout"
    assert_diag "$C07/expected/symlink-asset.stderr" "$OUT/logs/c07-symlink.stderr"
    assert_no_html_target "$OUT/outputs/c07-symlink"
    pass "c07-symlink: symlinked content asset rejected"
else
    pass "c07-symlink: host cannot create symlinks; skipped"
fi

gen="$OUT/generated/c07-traversal"
rm -rf "$gen"
mkdir -p "$gen/content/guides"
printf -- '---\ntitle: Intro\n---\n![alt](../secret.png)\n' >"$gen/content/guides/intro.md"
run_capture c07-traversal 1 "$BORIS" --html --input "$gen/content" --html-dir "$OUT/outputs/c07-traversal" --html-layout "$C07/layout.html"
assert_empty "$OUT/logs/c07-traversal.stdout"
assert_diag "$C07/expected/traversal-image.stderr" "$OUT/logs/c07-traversal.stderr"
assert_no_html_target "$OUT/outputs/c07-traversal"
pass "c07-traversal: out-of-tree image path fails closed"

run_capture c07-sitemap 2 "$BORIS" --html --input "$C07/content" --html-dir "$OUT/outputs/c07-sitemap" --html-layout "$C07/layout.html" --sitemap-path guides/intro.html --site-url https://example.test
assert_empty "$OUT/logs/c07-sitemap.stdout"
head -2 "$OUT/logs/c07-sitemap.stderr" >"$OUT/logs/c07-sitemap.head2"
assert_diag "$C07/expected/sitemap-content-collision.stderr" "$OUT/logs/c07-sitemap.head2"
assert_no_html_target "$OUT/outputs/c07-sitemap"
pass "c07-sitemap: sitemap path vs page output collision fails closed"

note "Publication conformance evidence verified; confirmed defects retained: none"
