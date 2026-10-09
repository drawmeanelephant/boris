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
note "init --help names every archetype"
"$ROOT/zig-out/bin/boris" init --help >"$OUT/init-help.stdout" 2>"$OUT/init-help.stderr" \
    || fail "init --help exited nonzero"
for t in docs garden cookbook blog textile; do
    grep -q "$t" "$OUT/init-help.stderr" || fail "init help does not name archetype $t"
done
pass "help names docs, garden, cookbook, blog, textile"

note "unknown --type is a usage error"
if "$ROOT/zig-out/bin/boris" init --type bogus "$OUT/bogus" >"$OUT/bogus.stdout" 2>"$OUT/bogus.stderr"; then
    fail "init accepted an unknown archetype"
fi
grep -q 'unknown init type' "$OUT/bogus.stderr" || fail "unknown-type diagnostic missing"
grep -q 'docs, garden, cookbook, blog, textile' "$OUT/bogus.stderr" || fail "unknown-type diagnostic did not list archetypes"
[[ ! -e "$OUT/bogus" ]] || fail "unknown type still wrote a tree"
pass "unknown archetype refused with the name list"

note "each archetype materializes and compiles through its declared profile"
for t in garden cookbook blog textile; do
    "$ROOT/zig-out/bin/boris" init --type "$t" "$OUT/arch-$t" >"$OUT/arch-$t.stdout" 2>"$OUT/arch-$t.stderr" \
        || fail "init --type $t exited nonzero: $(head -3 "$OUT/arch-$t.stderr")"
    [[ -f "$OUT/arch-$t/boris.json" ]] || fail "init --type $t wrote no boris.json"
    [[ ! -d "$OUT/arch-$t/.boris-init-probe" ]] || fail "init --type $t left its compile probe behind"
    (cd "$OUT/arch-$t" && "$ROOT/zig-out/bin/boris" --profile boris.json --quiet) \
        >"$OUT/arch-$t-build.stdout" 2>"$OUT/arch-$t-build.stderr" \
        || fail "archetype $t does not build through its own profile: $(head -3 "$OUT/arch-$t-build.stderr")"
    [[ -f "$OUT/arch-$t/dist/index.html" ]] || fail "archetype $t profile build wrote no index.html"
done
pass "garden, cookbook, blog, textile all init + profile-build"

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

note "archetype trees are deterministic too"
"$ROOT/zig-out/bin/boris" init --type=garden "$OUT/arch-garden-b" >"$OUT/garden-b.stdout" 2>"$OUT/garden-b.stderr" \
    || fail "second garden init failed"
diff -r "$OUT/arch-garden" "$OUT/arch-garden-b" -x dist >/dev/null \
    || fail "two garden inits produced different trees"
pass "byte-identical garden trees (--type=NAME form accepted)"

rm -rf "$OUT/site" "$OUT/site-b" "$OUT/occupied" "$OUT/projects" "$OUT/quiet-site" \
    "$OUT/arch-garden" "$OUT/arch-cookbook" "$OUT/arch-blog" "$OUT/arch-textile" "$OUT/arch-garden-b"
echo "boris-init: all assertions passed"
