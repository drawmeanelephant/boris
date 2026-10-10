#!/usr/bin/env bash
# Black-box test for `boris init`: the generated starter tree must build and
# validate out of the box, plan through the starter profile, refuse to clobber
# an existing project, and be byte-deterministic across runs.
#
# Run from the repository root, or through:
#
#   zig build test-boris-init
#
# All generated trees live under the ignored .zig-cache tree.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/boris-init"
[[ "$OUT" == ".zig-cache/boris-init" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd -P)"

# Every `--type` name, in enum order; docs is the default archetype.
ARCHETYPES=(docs garden cookbook blog textile landing wiki link-in-bio changelog resume newsletter)
ARCHETYPE_LIST="$(IFS=,; printf '%s' "${ARCHETYPES[*]}" | sed 's/,/, /g')"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

# --- the initialized tree is complete and deterministic ---------------------
note "boris init in an empty directory"
"$ROOT/zig-out/bin/boris" init "$OUT/site" >"$OUT/init.stdout" 2>"$OUT/init.stderr" || fail "boris init exited nonzero"
for f in \
    content/index.md \
    content/guides/getting-started.md \
    content/guides/publishing.md \
    themes/boris/layouts/main.html \
    themes/boris/assets/css/boris.css \
    boris.json \
    standard-site.json; do
    [[ -f "$OUT/site/$f" ]] || fail "init did not write $f"
done
grep -q 'did:plc:aaaaaaaaaaaaaaaaaaaaaaaa' "$OUT/site/standard-site.json" \
    || fail "Atmosphere starter DID is not the obvious fake placeholder"
grep -q 'did:plc:ewvi7nxzyoun6zhxrhs64oiz' "$OUT/site/standard-site.json" \
    && fail "Atmosphere starter reused the atproto.com fixture DID"
grep -q 'bsky.social' "$OUT/site/standard-site.json" \
    && fail "Atmosphere starter named bsky.social"
grep -q '"pds"' "$OUT/site/standard-site.json" \
    && fail "Atmosphere starter should omit pds so publish binds to discovery"
pass "starter tree written"

note "deterministic output"
"$ROOT/zig-out/bin/boris" init "$OUT/site-b" >"$OUT/init-b.stdout" 2>"$OUT/init-b.stderr" || fail "second init failed"
diff -r "$OUT/site" "$OUT/site-b" >/dev/null || fail "two init runs produced different trees"
pass "byte-identical trees"

# --- the starter builds, validates, and plans out of the box ---------------
note "the starter builds, validates, and plans out of the box"
cd "$OUT/site"
"$ROOT/zig-out/bin/boris" --input content --html-dir dist --theme themes/boris --quiet \
    >"$OUT/build.stdout" 2>"$OUT/build.stderr" || fail "starter build failed: $(head -3 "$OUT/build.stderr")"
[[ -f "$OUT/site/dist/index.html" ]] || fail "build wrote no index.html"
[[ -f "$OUT/site/dist/guides/getting-started.html" ]] || fail "build wrote no guides/getting-started.html"
rm -rf "$OUT/site/dist"
"$ROOT/zig-out/bin/boris" --input content --target public=dist --theme themes/boris --profile standard-site.json --quiet \
    >"$OUT/emit.stdout" 2>"$OUT/emit.stderr" || fail "profile HTML emit failed: $(head -5 "$OUT/emit.stderr")"
[[ -f "$OUT/site/dist/.well-known/site.standard.publication" ]] || fail "HTML emit wrote no well-known publication file"
[[ -f "$OUT/site/dist/_boris/proof/standard-site.json" ]] || fail "HTML emit wrote no verification report"
"$ROOT/zig-out/bin/boris" standard-site verify --profile standard-site.json --dist dist \
    >"$OUT/verify.json" 2>"$OUT/verify.stderr" || fail "verify against CLI-built dist failed: $(head -5 "$OUT/verify.stderr")"
grep -q '"overall_passed": true' "$OUT/verify.json" || fail "verify did not pass against the emitted dist"
"$ROOT/zig-out/bin/boris" validate --input content --theme themes/boris --quiet \
    >"$OUT/validate.stdout" 2>"$OUT/validate.stderr" || fail "starter validate failed: $(head -3 "$OUT/validate.stderr")"
"$ROOT/zig-out/bin/boris" plan --profile boris.json \
    >"$OUT/plan.json" 2>"$OUT/plan.stderr" || fail "starter profile did not plan"
grep -q '"format": "boris-publication-plan"' "$OUT/plan.json" || fail "plan output is not a publication plan"
"$ROOT/zig-out/bin/boris" standard-site plan --profile standard-site.json \
    >"$OUT/standard-site-plan.json" 2>"$OUT/standard-site-plan.stderr" \
    || fail "Atmosphere starter profile did not plan: $(head -3 "$OUT/standard-site-plan.stderr")"
grep -q '"format": "boris-standard-site-plan"' "$OUT/standard-site-plan.json" \
    || fail "Atmosphere plan output is not a standard-site plan"
grep -q 'did:plc:aaaaaaaaaaaaaaaaaaaaaaaa' "$OUT/standard-site-plan.json" \
    || fail "Atmosphere plan dropped the placeholder DID"
pass "starter builds, validates, and plans"

# --- refusal: never clobber an existing non-empty project ------------------
note "init refuses to clobber a non-empty directory"
mkdir -p "$OUT/occupied"
printf 'existing\n' > "$OUT/occupied/keep.txt"
if "$ROOT/zig-out/bin/boris" init "$OUT/occupied" >"$OUT/refuse.stdout" 2>"$OUT/refuse.stderr"; then
    fail "init accepted a non-empty directory"
fi
grep -q "refusing to overwrite" "$OUT/refuse.stderr" || fail "refusal message missing"
[[ -f "$OUT/occupied/keep.txt" ]] || fail "init modified the occupied directory"
pass "refusal enforced"

# --- nested targets: parents are created, not assumed ---------------------
note "init creates missing parent directories for a nested target"
"$ROOT/zig-out/bin/boris" init "$OUT/projects/site" >"$OUT/nested.stdout" 2>"$OUT/nested.stderr" \
    || fail "nested init failed: $(head -3 "$OUT/nested.stderr")"
[[ -f "$OUT/projects/site/boris.json" ]] || fail "nested init wrote no tree"
pass "nested target materialized"

# --- quiet suppresses the success chatter ----------------------------------
note "init --quiet prints nothing on success"
"$ROOT/zig-out/bin/boris" init --quiet "$OUT/quiet-site" >"$OUT/quiet.stdout" 2>"$OUT/quiet.stderr" \
    || fail "quiet init failed"
[[ -s "$OUT/quiet.stderr" ]] && fail "init --quiet still printed stderr: $(head -2 "$OUT/quiet.stderr")"
[[ -s "$OUT/quiet.stdout" ]] && fail "init --quiet still printed stdout"
pass "quiet silence honored"

# --- --type selects a starter archetype -------------------------------------
# Back to the workspace root: the archetype targets below must resolve inside
# the cwd workspace, or init skips its compile probe instead of running it.
cd "$ROOT"
note "init --help names every archetype"
"$ROOT/zig-out/bin/boris" init --help >"$OUT/init-help.stdout" 2>"$OUT/init-help.stderr" \
    || fail "init --help exited nonzero"
for t in "${ARCHETYPES[@]}"; do
    grep -q "^  $t " "$OUT/init-help.stderr" || fail "init help does not name archetype $t"
done
pass "help names $ARCHETYPE_LIST"

note "unknown --type is a usage error"
if "$ROOT/zig-out/bin/boris" init --type bogus "$OUT/bogus" >"$OUT/bogus.stdout" 2>"$OUT/bogus.stderr"; then
    fail "init accepted an unknown archetype"
fi
grep -q 'unknown init type' "$OUT/bogus.stderr" || fail "unknown-type diagnostic missing"
grep -qF "expected one of: $ARCHETYPE_LIST)" "$OUT/bogus.stderr" \
    || fail "unknown-type diagnostic did not list archetypes"
[[ ! -e "$OUT/bogus" ]] || fail "unknown type still wrote a tree"
pass "unknown archetype refused with the name list"

note "each archetype materializes, compiles, is deterministic, and refuses non-empty targets"
for t in "${ARCHETYPES[@]:1}"; do
    "$ROOT/zig-out/bin/boris" init --type "$t" "$OUT/arch-$t" >"$OUT/arch-$t.stdout" 2>"$OUT/arch-$t.stderr" \
        || fail "init --type $t exited nonzero: $(head -3 "$OUT/arch-$t.stderr")"
    grep -q '^verified: starter compiled [1-9][0-9]* page(s)$' "$OUT/arch-$t.stderr" \
        || fail "init --type $t did not report a verified probe compile"
    [[ -f "$OUT/arch-$t/boris.json" ]] || fail "init --type $t wrote no boris.json"
    [[ ! -d "$OUT/arch-$t/.boris-init-probe" ]] || fail "init --type $t left its compile probe behind"
    "$ROOT/zig-out/bin/boris" init --quiet --type="$t" "$OUT/arch-$t-b" >/dev/null 2>"$OUT/arch-$t-b.stderr" \
        || fail "second init --type $t failed: $(head -3 "$OUT/arch-$t-b.stderr")"
    diff -r "$OUT/arch-$t" "$OUT/arch-$t-b" >/dev/null || fail "two init --type $t runs produced different trees"
    if "$ROOT/zig-out/bin/boris" init --type "$t" "$OUT/occupied" >/dev/null 2>"$OUT/refuse-$t.stderr"; then
        fail "init --type $t accepted a non-empty directory"
    fi
    grep -q "refusing to overwrite" "$OUT/refuse-$t.stderr" || fail "init --type $t refusal message missing"
    [[ "$(ls -A "$OUT/occupied")" == "keep.txt" ]] || fail "init --type $t modified the occupied directory"
    (cd "$OUT/arch-$t" && "$ROOT/zig-out/bin/boris" --profile boris.json --quiet) \
        >"$OUT/arch-$t-build.stdout" 2>"$OUT/arch-$t-build.stderr" \
        || fail "archetype $t does not build through its own profile: $(head -3 "$OUT/arch-$t-build.stderr")"
    [[ -f "$OUT/arch-$t/dist/index.html" ]] || fail "archetype $t profile build wrote no index.html"
done
pass "${ARCHETYPE_LIST#docs, }: init + byte-identical rerun + refusal + profile-build"

note "archetype surfaces are honest"
grep -q '"input_format": "cook"' "$OUT/arch-cookbook/boris.json" \
    || fail "cookbook profile does not declare input_format: cook"
grep -q '"input_format": "textile"' "$OUT/arch-textile/boris.json" \
    || fail "textile profile does not declare input_format: textile"
find "$OUT/arch-cookbook/content" -name '*.cook' | grep -q . || fail "cookbook wrote no .cook pages"
find "$OUT/arch-textile/content" -name '*.textile' | grep -q . || fail "textile wrote no .textile pages"
grep -q 'recipe-scale' "$OUT/arch-cookbook/content/index.cook" \
    || fail "cookbook index does not point at boris recipe-scale"
grep -q '{{include ' "$OUT/arch-garden/content/notes/composition.md" \
    || fail "garden lost its include demo"
[[ -d "$OUT/arch-garden/content/includes" ]] || fail "garden wrote no includes/ fragments"
grep -q '<Aside kind=' "$OUT/arch-garden/content/index.md" \
    || fail "garden lost its registered-component demo"
(cd "$OUT/arch-cookbook" && "$ROOT/zig-out/bin/boris" recipe-scale --cooklang --id mains/carbonara --servings 4) \
    >"$OUT/recipe-scale.json" 2>"$OUT/recipe-scale.stderr" \
    || fail "recipe-scale failed inside the cookbook starter: $(head -3 "$OUT/recipe-scale.stderr")"
grep -q '"target": 4' "$OUT/recipe-scale.json" || fail "recipe-scale did not scale to 4 servings"
pass "formats, includes, components, and recipe-scale all exercise their seams"

# --- wave-1 archetypes: each teaches the primitive its issue names ---------
note "landing: one trunk page composed from includes, index on the home layout"
L="$OUT/arch-landing/dist"
grep -q 'govuk-home-grid' "$L/index.html" || fail "landing index does not use the service home layout"
grep -q 'govuk-home-grid' "$L/about.html" && fail "landing about should fall back to main.html"
grep -q 'govuk-breadcrumbs' "$L/about.html" || fail "landing about is not on the service main layout"
grep -q 'What we do' "$L/index.html" || fail "landing index did not splice includes/services.md"
grep -q 'Do I need an appointment' "$L/index.html" || fail "landing index did not splice includes/faq.md"
grep -q 'Open Tuesday to Saturday' "$L/index.html" || fail "landing index did not splice includes/visit.md"
[[ ! -e "$L/includes" ]] || fail "landing include fragments compiled as pages"
pass "landing: home layout on index, main on about, three fragments spliced"

note "wiki: breadcrumbs walk the three-level chain; hubs and index use named layouts"
W="$OUT/arch-wiki/dist"
grep -q 'home-shell' "$W/index.html" || fail "wiki index does not use the reference home layout"
grep -q 'section-children' "$W/wiki/tools.html" || fail "wiki hub does not use the reference section layout"
grep -q 'section-children' "$W/wiki/tools/chisels.html" && fail "wiki entry should fall back to main.html"
crumbs="$(sed -n '/<nav class="breadcrumb"/,/<\/nav>/p' "$W/wiki/tools/chisels.html")"
for crumb in '>Workshop Wiki</a>' '>Tools</a>' 'aria-current="page">Chisels<'; do
    grep -qF "$crumb" <<<"$crumbs" || fail "wiki entry breadcrumb is missing $crumb"
done
grep -q 'href="../techniques/sharpening.html"' "$W/wiki/tools/chisels.html" \
    || fail "wiki cross-entry link did not resolve"
pass "wiki: index → hub → entry breadcrumb, home/section/main layouts, cross-entry links"

note "link-in-bio: one page is a complete, checkable site"
grep -q '^verified: starter compiled 1 page(s)$' "$OUT/arch-link-in-bio.stderr" \
    || fail "link-in-bio probe did not compile exactly one page"
[[ "$(find "$OUT/arch-link-in-bio/dist" -name '*.html' -not -path '*/_boris/*' | wc -l | tr -d ' ')" == 1 ]] \
    || fail "link-in-bio profile build wrote more than one page"
grep -q 'href="https://example.com/shop"' "$OUT/arch-link-in-bio/dist/index.html" \
    || fail "link-in-bio link list did not render"
(cd "$OUT/arch-link-in-bio" && "$ROOT/zig-out/bin/boris" check) >"$OUT/link-in-bio-check.stdout" 2>"$OUT/link-in-bio-check.stderr" \
    || fail "boris check failed on the one-page site: $(head -3 "$OUT/link-in-bio-check.stderr")"
pass "link-in-bio: one page compiled, built, and checked"

note "changelog: the draft entry renders but is kept out of search, RSS, and sitemap"
C="$OUT/arch-changelog"
[[ -f "$C/dist/changes/unreleased.html" ]] || fail "changelog draft entry did not render"
grep -q '"path": "changes/2026-09-28-v0-2-0.html"' "$C/dist/_boris/search/search-index.json" \
    || fail "changelog search index is missing a published release"
grep -q 'changes/unreleased' "$C/dist/_boris/search/search-index.json" \
    && fail "changelog draft entry leaked into the search index"
(cd "$C" && "$ROOT/zig-out/bin/boris" --rss --input content --site-url https://tidepool.example.com/ \
    --rss-title "Tidepool" --rss-description "Release notes" --rss-path feed/rss.xml --quiet) \
    >/dev/null 2>"$OUT/changelog-rss.stderr" || fail "changelog RSS export failed: $(head -3 "$OUT/changelog-rss.stderr")"
grep -q '<link>https://tidepool.example.com/changes/2026-08-17-v0-1-0.html</link>' "$C/feed/rss.xml" \
    || fail "changelog feed is missing a published release"
grep -q 'unreleased' "$C/feed/rss.xml" && fail "changelog draft entry leaked into the RSS feed"
(cd "$C" && "$ROOT/zig-out/bin/boris" --input content --html-dir dist-sitemap --theme themes/journal \
    --sitemap --site-url https://tidepool.example.com/ --quiet) >/dev/null 2>"$OUT/changelog-sitemap.stderr" \
    || fail "changelog sitemap build failed: $(head -3 "$OUT/changelog-sitemap.stderr")"
grep -q 'changes/2026-09-28-v0-2-0.html' "$C/dist-sitemap/sitemap.xml" || fail "changelog sitemap is missing a release"
grep -q 'unreleased' "$C/dist-sitemap/sitemap.xml" && fail "changelog draft entry leaked into the sitemap"
pass "changelog: draft emitted at its route; absent from search index, RSS, and sitemap"

note "resume: the CV page carries its tags through {{metadata}} and ships a print stylesheet"
R="$OUT/arch-resume"
grep -q '<dd>production-editing, typesetting, publishing-systems</dd>' "$R/dist/index.html" \
    || fail "resume {{metadata}} did not render the CV tags"
[[ -f "$R/dist/now.html" ]] || fail "resume now satellite did not render"
grep -q '@media print' "$R/dist/assets/corporate.css" || fail "resume theme ships no print stylesheet"
pass "resume: tags in metadata, now satellite, print stylesheet published"

note "newsletter: press named layouts, a profile-declared sitemap, and feed-ready issues"
N="$OUT/arch-newsletter"
grep -q 'txp-home' "$N/dist/index.html" || fail "newsletter index does not use the press home layout"
grep -q 'txp-archive-body' "$N/dist/issues.html" || fail "newsletter issues hub does not use the press archive layout"
grep -q 'txp-blog-body' "$N/dist/issues/2026-10-03-the-paper-mill.html" \
    || fail "newsletter issue does not use the press blog layout"
grep -q '<loc>https://saturday-sheet.example.com/issues/2026-09-19-first-edition.html</loc>' "$N/dist/sitemap.xml" \
    || fail "newsletter profile build did not emit the sitemap"
(cd "$N" && "$ROOT/zig-out/bin/boris" --rss --input content --site-url https://saturday-sheet.example.com/ \
    --rss-title "The Saturday Sheet" --rss-description "A weekly paper" --rss-path feed/rss.xml --quiet) \
    >/dev/null 2>"$OUT/newsletter-rss.stderr" || fail "newsletter RSS export failed: $(head -3 "$OUT/newsletter-rss.stderr")"
[[ "$(grep -c '<item>' "$N/feed/rss.xml")" == 3 ]] || fail "newsletter issues are not all feed-eligible"
pass "newsletter: home/archive/blog layouts, dist/sitemap.xml, three feed-eligible issues"

rm -rf "$OUT/site" "$OUT/site-b" "$OUT/occupied" "$OUT/projects" "$OUT/quiet-site"
for t in "${ARCHETYPES[@]:1}"; do rm -rf "$OUT/arch-$t" "$OUT/arch-$t-b"; done
echo "boris-init: all assertions passed"
