#!/usr/bin/env bash
# Executable black-box conformance verification for the retained C02/C03/C04/C08
# publication evidence. Run from the repository root, or through:
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
OUT=".zig-cache/publication-conformance"
C02="docs/audits/publication-conformance/c02-includes-fragments"
C03="docs/audits/publication-conformance/c03-sitemap"
C04="docs/audits/publication-conformance/c04-rss"
C08="docs/audits/publication-conformance/c08-parser-unicode"
LAYOUT="$C02/layout.html"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

[[ -x "$BORIS" ]] || fail "missing installed Boris binary at ${BORIS}"
[[ -f "$C02/depth-cases.tsv" ]] || fail "missing generated-depth declaration"

# This path is fixed and ignored by the repository. Keep the guard adjacent to
# the cleanup so a future edit cannot accidentally widen the deletion scope.
[[ "$OUT" == ".zig-cache/publication-conformance" ]] || fail "unsafe verifier output path"
rm -rf "$OUT"
mkdir -p "$OUT/logs" "$OUT/outputs" "$OUT/generated"
cleanup() {
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

assert_no_ir_target() {
    local path="$1"
    assert_absent "$path/graph.json"
    assert_absent "$path/manifest.json"
    assert_file "$path/build-report.json"
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

assert_stderr_contains() {
    local needle="$1"
    local path="$2"
    grep -F "$needle" "$path" >/dev/null || fail "${path} does not contain ${needle}"
}

run_html_success() {
    local name="$1"
    local input="$2"
    local expected_html="$3"
    local extra_name="$4"
    shift 4
    local first="$OUT/outputs/${extra_name}-a"
    local second="$OUT/outputs/${extra_name}-b"

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
run_html_success "c02-01" "$C02/cases/01-include-success/content" "$C02/cases/01-include-success/expected/index.html" "c02-01"
run_html_failure "c02-02" "$C02/cases/02-missing-include/content" "$C02/cases/02-missing-include/expected/stderr.txt"
run_html_failure "c02-03" "$C02/cases/03-direct-cycle/content" "$C02/cases/03-direct-cycle/expected/stderr.txt"
run_html_failure "c02-04" "$C02/cases/04-long-cycle/content" "$C02/cases/04-long-cycle/expected/stderr.txt"
run_html_success "c02-05" "$C02/cases/05-valid-fragment/content" "$C02/cases/05-valid-fragment/expected/index.html" "c02-05"
run_html_failure "c02-06" "$C02/cases/06-missing-fragment/content" "$C02/cases/06-missing-fragment/expected/stderr.txt"
run_html_success "c02-07" "$C02/cases/07-fragment-after-include/content" "$C02/cases/07-fragment-after-include/expected/index.html" "c02-07"
run_html_success "c02-08" "$C02/cases/08-duplicate-heading/content" "$C02/cases/08-duplicate-heading/expected/index.html" "c02-08"
assert_cmp "$C02/cases/08-duplicate-heading/expected/target.html" "$OUT/outputs/c02-08-a/target.html"
run_html_success "c02-09" "$C02/cases/09-nested-include-path/content" "$C02/cases/09-nested-include-path/expected/index.html" "c02-09"

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
done <"$C02/depth-cases.tsv"

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
    assert_no_ir_target "$output"
done
invalid_utf8_out="$OUT/outputs/c08-invalid-utf8"
run_capture c08-invalid-utf8 1 "$BORIS" --no-rag --input fixtures/content/invalid --out "$invalid_utf8_out"
assert_empty "$OUT/logs/c08-invalid-utf8.stdout"
assert_diag "$C08/expected/invalid-utf8.stderr" "$OUT/logs/c08-invalid-utf8.stderr"
assert_no_ir_target "$invalid_utf8_out"
pass "c08-invalid: BOM, malformed Unicode, and invalid UTF-8 fail closed"

note "Publication conformance verification passed"
