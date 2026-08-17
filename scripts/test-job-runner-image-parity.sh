#!/usr/bin/env bash
# Optional parity smoke for boris-job-runner (#300).
#
# Builds the example container image, runs the valid and poisoned fixtures
# through `docker run`, and byte-diffs the resulting artifacts against a
# native `--once` run. This is an operator-parity check, NOT a release gate:
# it is wired to `workflow_dispatch` only (manual), and the native --once
# smoke in scripts/test-job-runner-image.sh remains the required CI check.
#
# Skips cleanly when Docker is unavailable or the host is not linux/amd64
# (the image and its ReleaseSafe binaries are linux/amd64). It is not a live
# Cloudflare run and does not claim macOS-vs-Linux byte identity.
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
  skip "image parity is linux/amd64 (host is ${uname_s}/${uname_m})"
fi

note "build ReleaseSafe boris + boris-job-runner"
zig build -Doptimize=ReleaseSafe
[[ -x zig-out/bin/boris ]] || fail "missing zig-out/bin/boris"
[[ -x zig-out/bin/boris-job-runner ]] || fail "missing zig-out/bin/boris-job-runner"

EX="$ROOT/examples/cloudflare-container"
mkdir -p "$EX/bin"
cp zig-out/bin/boris zig-out/bin/boris-job-runner "$EX/bin/"
trap 'rm -rf "$EX/bin"' EXIT

note "docker build"
docker build -f "$EX/Dockerfile" -t boris-job-runner:parity "$EX"

OUT="$ROOT/.zig-cache/job-runner-parity"
rm -rf "$OUT"
mkdir -p "$OUT/native" "$OUT/image"

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

BORIS="$ROOT/zig-out/bin/boris"
RUNNER="$ROOT/zig-out/bin/boris-job-runner"

run_native() {
  local archive="$1" json="$2" tar="$3" ws="$4"
  "$RUNNER" --once --boris "$BORIS" --archive "$archive" \
    --result-json "$json" --result-tar "$tar" --work-root "$ws"
}

run_image() {
  local archive="$1" json="$2" tar="$3"
  local cid outlog rc
  outlog="$OUT/$(basename "$archive")-container.log"
  # Write results inside the container (/tmp is world-writable) and copy them
  # out. Do not override --entrypoint: the image already starts
  # boris-job-runner, and extra args replace CMD. Read-only bind mount for
  # the archive sidesteps the image's non-root uid 65532.
  cid="$(docker create \
    --network none \
    --workdir / \
    -v "$archive:/in.tar:ro" \
    boris-job-runner:parity \
    --once --boris /usr/local/bin/boris --archive /in.tar \
    --result-json /tmp/result.json --result-tar /tmp/package.tar \
    --work-root /tmp/boris-jobs)"
  set +e
  docker start -a "$cid" > "$outlog" 2>&1
  rc=$?
  set -e
  docker cp "$cid:/tmp/result.json" "$json" 2>/dev/null || true
  docker cp "$cid:/tmp/package.tar" "$tar" 2>/dev/null || true
  docker rm -f "$cid" >/dev/null
  if [[ "$rc" -ne 0 ]]; then
    printf '    container log (%s):\n' "$outlog" >&2
    cat "$outlog" >&2
    if [[ -f "$json" ]]; then
      printf '    container result (%s):\n' "$json" >&2
      cat "$json" >&2
    fi
  fi
  return "$rc"
}

note "native reference runs (valid + poisoned)"
set +e
run_native "$OUT/valid.tar" "$OUT/native/valid.json" "$OUT/native/package.tar" "$OUT/native/ws"
native_valid_rc=$?
run_native "$OUT/poisoned.tar" "$OUT/native/poisoned.json" "$OUT/native/poisoned-package.tar" "$OUT/native/ws2"
native_poisoned_rc=$?
set -e
[[ "$native_valid_rc" -eq 0 ]] || fail "native valid run exited $native_valid_rc, expected 0"
[[ "$native_poisoned_rc" -eq 1 ]] || fail "native poisoned run exited $native_poisoned_rc, expected 1"
pass "native reference runs complete"

note "valid fixture through the image"
set +e
run_image "$OUT/valid.tar" "$OUT/image/valid.json" "$OUT/image/package.tar"
image_valid_rc=$?
set -e
[[ "$image_valid_rc" -eq 0 ]] || fail "image valid run exited $image_valid_rc, expected 0"
[[ -f "$OUT/image/valid.json" ]] || fail "image valid.json not copied out"
[[ -f "$OUT/image/package.tar" ]] || fail "image package.tar not copied out"

note "poisoned fixture through the image"
set +e
run_image "$OUT/poisoned.tar" "$OUT/image/poisoned.json" "$OUT/image/poisoned-package.tar"
image_poisoned_rc=$?
set -e
[[ "$image_poisoned_rc" -eq 1 ]] || fail "image poisoned run exited $image_poisoned_rc, expected 1"
pass "image runs complete"

cmp_artifacts() {
  local native_json="$1" native_tar="$2" image_json="$3" image_tar="$4" label="$5"
  mkdir -p "$OUT/cmp-$label-native" "$OUT/cmp-$label-image"
  tar -xf "$native_tar" -C "$OUT/cmp-$label-native"
  tar -xf "$image_tar" -C "$OUT/cmp-$label-image"
  # The artifact manifest (paths + sizes) must agree; timings and other
  # transport metadata are excluded from the byte comparison by contract.
  python3 - "$native_json" "$image_json" "$label" <<'PY'
import json, sys
n, i, label = json.load(open(sys.argv[1])), json.load(open(sys.argv[2])), sys.argv[3]
na = sorted((a["path"], a["size"]) for a in n["artifacts"])
ia = sorted((a["path"], a["size"]) for a in i["artifacts"])
assert n["ok"] == i["ok"], (label, n["ok"], i["ok"])
assert na == ia, (label, "artifact manifest mismatch", na, ia)
print(f"    {label}: manifest agrees ({len(na)} artifacts)")
PY
  diff -r "$OUT/cmp-$label-native/artifacts" "$OUT/cmp-$label-image/artifacts" >/dev/null \
    || fail "$label: artifact bytes differ between native and image"
  pass "$label: artifacts byte-identical native vs image"
}

cmp_artifacts "$OUT/native/valid.json" "$OUT/native/package.tar" \
  "$OUT/image/valid.json" "$OUT/image/package.tar" "valid"

python3 - "$OUT/native/poisoned.json" "$OUT/image/poisoned.json" <<'PY'
import json, sys
n, i = json.load(open(sys.argv[1])), json.load(open(sys.argv[2]))
assert n["ok"] is False and i["ok"] is False, (n["ok"], i["ok"])
assert n["runnerClass"] == i["runnerClass"] == "content", (n["runnerClass"], i["runnerClass"])
assert n["artifacts"] == i["artifacts"] == [], (n["artifacts"], i["artifacts"])
assert any(d["code"] == "EPARENTMISSING" for d in n["diagnostics"]), "native missing EPARENTMISSING"
assert any(d["code"] == "EPARENTMISSING" for d in i["diagnostics"]), "image missing EPARENTMISSING"
print("    poisoned: both sides failed closed with EPARENTMISSING, no artifacts")
PY
pass "poisoned: image failed closed identically to native"

note "job-runner image parity complete"
