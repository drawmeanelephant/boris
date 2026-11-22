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
ARCHETYPES=(docs garden cookbook blog textile photo-gallery)
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
    themes/boris/footer.html \
    themes/boris/assets/css/boris.css \
    themes/boris/assets/favicon.svg \
    themes/boris/assets/search.html \
    themes/boris/README.md \
    themes/boris/ACCESSIBILITY.md \
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
# The starter's one relation is visible on both ends (#1063): the theme
# renders {{relations}} on the source and {{backlinks}} on the target.
docs_rel() { sed -n "/<section class=\"semantic-$1\"/,/<\/section>/p" "$OUT/site/dist/guides/$2.html"; }
docs_rel relations publishing | grep -q 'data-relation-kind="relates_to".*href="getting-started.html"' \
    || fail "docs relates_to relation did not render on guides/publishing"
docs_rel backlinks getting-started | grep -q 'data-relation-kind="relates_to".*href="publishing.html"' \
    || fail "docs relates_to backlink did not render on guides/getting-started"
grep -q '<nav class="page-children"' "$OUT/site/dist/index.html" || fail "docs index has no {{children}} list"
grep -q 'data-boris-search-ui' "$OUT/site/dist/index.html" || fail "docs index has no search UI"
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
[[ "$(ls -A "$OUT/occupied")" == "keep.txt" ]] || fail "init left its claim file in the occupied directory"
pass "refusal enforced"

# --- concurrency: racing inits cannot both write the same target ----------
# Issue #1099: without the .boris-init.lock claim, two inits could both pass
# the emptiness check and a failure would delete the shared tree.
note "two concurrent inits on one target: exactly one wins"
"$ROOT/zig-out/bin/boris" init "$OUT/raced" >"$OUT/race-a.stdout" 2>"$OUT/race-a.stderr" &
race_a=$!
"$ROOT/zig-out/bin/boris" init "$OUT/raced" >"$OUT/race-b.stdout" 2>"$OUT/race-b.stderr" &
race_b=$!
rc_a=0; wait "$race_a" || rc_a=$?
rc_b=0; wait "$race_b" || rc_b=$?
if ! { [[ $rc_a -eq 0 && $rc_b -ne 0 ]] || [[ $rc_a -ne 0 && $rc_b -eq 0 ]]; }; then
    fail "raced inits: expected exactly one success (a=$rc_a b=$rc_b)"
fi
# The target is either a complete starter or gone — never half-written, and
# never carrying a leftover claim or probe tree.
if [[ -d "$OUT/raced" ]]; then
    for f in boris.json content/index.md themes/boris/layouts/main.html; do
        [[ -f "$OUT/raced/$f" ]] || fail "raced target exists but is not a complete starter ($f missing)"
    done
    [[ ! -e "$OUT/raced/.boris-init.lock" ]] || fail "raced target kept the claim file"
    [[ ! -d "$OUT/raced/.boris-init-probe" ]] || fail "raced target kept the probe tree"
fi
# Whichever run lost refused cleanly instead of writing into a claimed tree.
if [[ $rc_a -ne 0 ]]; then loser_err="$OUT/race-a.stderr"; else loser_err="$OUT/race-b.stderr"; fi
grep -qE "refusing to overwrite|boris-init\.lock" "$loser_err" \
    || fail "raced loser did not refuse cleanly: $(head -3 "$loser_err")"
pass "raced inits: one winner, target whole or untouched"

note "init refuses a target claimed by another init"
mkdir -p "$OUT/claimed"
: > "$OUT/claimed/.boris-init.lock"
if "$ROOT/zig-out/bin/boris" init "$OUT/claimed" >"$OUT/claimed.stdout" 2>"$OUT/claimed.stderr"; then
    fail "init accepted a claimed directory"
fi
grep -q "boris-init\.lock" "$OUT/claimed.stderr" || fail "claim refusal did not name the claim file"
[[ "$(ls -A "$OUT/claimed")" == ".boris-init.lock" ]] || fail "init modified the claimed directory"
pass "claimed target refused and untouched"

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
for t in "${ARCHETYPES[@]}"; do
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
    # A starter's theme is the catalog theme's whole file set, byte for byte:
    # a missing sibling (ACCESSIBILITY.md, an asset) is a dead README link.
    for th in "$OUT/arch-$t/themes/"*/; do
        name="$(basename "$th")"
        diff -r -x .DS_Store "$ROOT/themes/$name" "$th" >"$OUT/arch-$t-theme-$name.diff" 2>&1 \
            || fail "archetype $t theme $name differs from themes/$name: $(head -3 "$OUT/arch-$t-theme-$name.diff")"
    done
done
pass "$ARCHETYPE_LIST: init + byte-identical rerun + refusal + profile-build + full theme file set"
diff -r "$OUT/site/themes" "$OUT/arch-docs/themes" >/dev/null || fail "default init and --type docs wrote different themes"
for f in content/index.md content/guides/getting-started.md content/guides/publishing.md boris.json standard-site.json; do
    cmp -s "$OUT/site/$f" "$OUT/arch-docs/$f" || fail "default init and --type docs differ at $f"
done
pass "the default init is --type docs"

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
# The profile's id:index rule selects a .cook page like any other input.
K="$OUT/arch-cookbook/dist"
grep -q 'data-layout="home"' "$K/index.html" || fail "cookbook index does not use the cards home layout"
deck="$(sed -n '/<section class="home-deck"/,/<\/section>/p' "$K/index.html")"
grep -q '<nav class="page-children"' <<<"$deck" || fail "cookbook home deck has no {{children}} list"
for recipe in mains/carbonara mains/pancakes sauces/pepper-oil; do
    grep -q '<main id="content" class="article-card"' "$K/$recipe.html" || fail "cookbook $recipe is not on the cards main layout"
    grep -q 'data-layout="home"' "$K/$recipe.html" && fail "cookbook $recipe should fall back to main.html"
    grep -q "href=\"$recipe.html\"" <<<"$deck" || fail "cookbook home deck does not list $recipe"
done
pass "formats, includes, components, and recipe-scale all exercise their seams; cookbook index deck on home.html"

note "blog: profile-declared feed with autodiscovery, sitemap, and draft gating"
B="$OUT/arch-blog"
[[ -f "$B/dist/posts/2026-10-12-in-progress.html" ]] || fail "blog draft post did not render"
grep -q 'class="entry entry--draft"' "$B/dist/posts/2026-10-12-in-progress.html" \
    || fail "blog draft post did not carry entry--draft"
grep -q '<loc>https://the-corner.example.com/posts/2026-09-14-first-post.html</loc>' "$B/dist/sitemap.xml" \
    || fail "blog profile build did not emit the sitemap"
[[ -f "$B/dist/feed.xml" ]] || fail "blog profile build did not emit dist/feed.xml"
[[ "$(grep -c '<item>' "$B/dist/feed.xml")" == 3 ]] || fail "blog feed does not carry all three published posts"
grep -q '2026-10-12-in-progress' "$B/dist/feed.xml" "$B/dist/sitemap.xml" \
    && fail "blog draft post leaked into feed.xml or sitemap.xml"
grep -q '2026-10-12-in-progress' "$B/dist/_boris/search/search-index.json" \
    && fail "blog draft post leaked into the search index"
sed -n '/<section class="recent-posts"/,/<\/section>/p' "$B/dist/posts.html" | grep -q '2026-10-12-in-progress' \
    && fail "blog draft post leaked into posts {{children}}"
sed -n '/<nav class="site-nav"/,/<\/nav>/p' "$B/dist/posts.html" | grep -q '2026-10-12-in-progress' \
    && fail "blog draft post leaked into {{nav}}"
autodiscovery='<link rel="alternate" type="application/rss+xml" href="https://the-corner.example.com/feed.xml">'
for page in index about posts posts/2026-09-14-first-post; do
    sed -n '/<head>/,/<\/head>/p' "$B/dist/$page.html" | grep -qF "$autodiscovery" \
        || fail "blog $page head has no feed autodiscovery link"
done
grep -q 'application/rss+xml' "$B/dist/posts/2026-10-12-in-progress.html" \
    && fail "blog draft post head advertises the feed"
pass "blog: dist/feed.xml (3 items) + head autodiscovery, sitemap; draft rendered at route and held back from feed, sitemap, search, and nav"

note "photo-gallery: every page's images resolve page-relative to byte-identical copies"
G="$OUT/arch-photo-gallery"
grep -q 'data-layout="home"' "$G/dist/index.html" || fail "photo-gallery index does not use the gallery home layout"
for album in coast hills; do
    grep -q "href=\"photos/$album.html\"" "$G/dist/index.html" || fail "photo-gallery album grid does not link $album"
done
images=0
for page in index photos/coast photos/hills; do
    srcs="$(grep -o '<img src="[^"]*"' "$G/dist/$page.html" | sed 's/^<img src="//; s/"$//')"
    [[ -n "$srcs" ]] || fail "photo-gallery $page renders no images"
    dir="$(dirname "$page")"
    stem="$(basename "$page")"
    while read -r src; do
        [[ "$src" == "$stem.assets/"* ]] || fail "photo-gallery $page image $src is not page-relative to its own assets"
        cmp -s "$G/dist/$dir/$src" "$G/content/$dir/$src" || fail "photo-gallery $page image $src did not publish beside the page"
        images=$((images + 1))
    done <<<"$srcs"
done
[[ "$images" == 5 ]] || fail "photo-gallery rendered $images images, expected 5"
grep -q '<figcaption><strong>Dawn.</strong>' "$G/dist/photos/coast.html" || fail "photo-gallery figure caption did not render"
pass "photo-gallery: home grid; 5 images at depths 0 and 1 resolve page-relative and publish byte-identical"

rm -rf "$OUT/site" "$OUT/site-b" "$OUT/occupied" "$OUT/projects" "$OUT/quiet-site" "$OUT/raced" "$OUT/claimed"
for t in "${ARCHETYPES[@]}"; do rm -rf "$OUT/arch-$t" "$OUT/arch-$t-b"; done
echo "boris-init: all assertions passed"
