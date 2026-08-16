#!/usr/bin/env bash
# Image smoke for boris-job-runner (#300).
#
# Builds linux binaries when already on linux/amd64, copies them into the
# example image, runs the valid and poisoned fixtures through `docker run`.
# Skips cleanly when Docker is not available. This is not a live Cloudflare
# gate and does not claim macOS-vs-Linux parity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
skip() { printf '    SKIP %s\n' "$*"; exit 0; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

command -v docker >/dev/null 2>&1 || skip "docker not on PATH"
docker info >/dev/null 2>&1 || skip "docker daemon not reachable"

uname_m="$(uname -m)"
uname_s="$(uname -s)"
if [[ "$uname_s" != "Linux" || ( "$uname_m" != "x86_64" && "$uname_m" != "amd64" ) ]]; then
  skip "image smoke is linux/amd64 (host is ${uname_s}/${uname_m})"
fi

note "build ReleaseSafe boris + boris-job-runner"
zig build -Doptimize=ReleaseSafe
[[ -x zig-out/bin/boris ]] || fail "missing zig-out/bin/boris"
[[ -x zig-out/bin/boris-job-runner ]] || fail "missing zig-out/bin/boris-job-runner"

EX="$ROOT/examples/cloudflare-container"
mkdir -p "$EX/bin"
cp zig-out/bin/boris zig-out/bin/boris-job-runner "$EX/bin/"

note "docker build"
docker build -f "$EX/Dockerfile" -t boris-job-runner:test "$EX"

OUT=".zig-cache/job-runner-image"
rm -rf "$OUT"
mkdir -p "$OUT"

pack() {
  local src="$1" dest="$2"
  python3 - "$src" "$dest" <<'PY'
import sys, tarfile, pathlib
src, dest = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
with tarfile.open(dest, "w") as t:
    for p in sorted(src.rglob("*")):
        if p.is_file():
            t.add(p, arcname="content/" + str(p.relative_to(src)))
PY
}

pack docs/contracts/fixtures/valid/content "$OUT/valid.tar"
pack docs/contracts/fixtures/missing-parent/content "$OUT/poisoned.tar"

run_once() {
  local archive="$1" json="$2"
  docker run --rm \
    --network none \
    --memory 1g --cpus 0.25 \
    -e BORIS_BIN=/usr/local/bin/boris \
    -v "$archive:/in.tar:ro" \
    -v "$OUT:/out" \
    --entrypoint /usr/local/bin/boris-job-runner \
    boris-job-runner:test \
    --once --archive /in.tar --result-json /out/"$(basename "$json")" --work-root /tmp/boris-jobs \
    || true
}

note "valid fixture through the image"
run_once "$OUT/valid.tar" "$OUT/valid.json"
[[ -f "$OUT/valid.json" ]] || fail "valid.json not written"
python3 - "$OUT/valid.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is True, d
assert d["runnerClass"] == "ok", d
assert d["retried"] is False, d
assert any(a["path"].endswith("index.html") for a in d["artifacts"]), d
print("valid ok, artifacts", len(d["artifacts"]))
PY
pass "valid fixture compiled inside the image"

note "poisoned fixture through the image"
set +e
run_once "$OUT/poisoned.tar" "$OUT/poisoned.json"
set -e
[[ -f "$OUT/poisoned.json" ]] || fail "poisoned.json not written"
python3 - "$OUT/poisoned.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d["ok"] is False, d
assert d["runnerClass"] == "content", d
assert d["artifacts"] == [], d
assert any(x["code"] == "EPARENTMISSING" for x in d["diagnostics"]), d
print("poisoned closed correctly")
PY
pass "poisoned fixture failed closed, no artifacts"

note "image smoke complete"
