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

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

BORIS="./zig-out/bin/boris"
[[ -x "$BORIS" ]] || { echo "missing installed Boris binary at $BORIS (run: zig build)" >&2; exit 1; }

OUT=".zig-cache/boris-init"
[[ "$OUT" == ".zig-cache/boris-init" ]] || { echo "unsafe test output path" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"

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
    boris.json; do
    [[ -f "$OUT/site/$f" ]] || fail "init did not write $f"
done
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
"$ROOT/zig-out/bin/boris" validate --input content --theme themes/boris --quiet \
    >"$OUT/validate.stdout" 2>"$OUT/validate.stderr" || fail "starter validate failed: $(head -3 "$OUT/validate.stderr")"
"$ROOT/zig-out/bin/boris" plan --profile boris.json \
    >"$OUT/plan.json" 2>"$OUT/plan.stderr" || fail "starter profile did not plan"
grep -q '"format": "boris-publication-plan"' "$OUT/plan.json" || fail "plan output is not a publication plan"
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

rm -rf "$OUT/site" "$OUT/site-b" "$OUT/occupied"
echo "boris-init: all assertions passed"
