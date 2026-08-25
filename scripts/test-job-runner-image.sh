#!/usr/bin/env bash
# Linux smoke for boris-job-runner (#300).
#
# Required path: native --once against the valid and poisoned fixtures.
# That is the compiler contract. The Docker image remains an operator
# example; it is not this job's gate. This is not a live Cloudflare run
# and does not claim macOS-vs-Linux byte identity.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

note() { printf '==> %s\n' "$*"; }
pass() { printf '    OK  %s\n' "$*"; }
fail() { printf '    FAIL %s\n' "$*" >&2; exit 1; }

note "build ReleaseSafe boris + boris-job-runner"
zig build -Doptimize=ReleaseSafe
[[ -x zig-out/bin/boris ]] || fail "missing zig-out/bin/boris"
[[ -x zig-out/bin/boris-job-runner ]] || fail "missing zig-out/bin/boris-job-runner"

OUT="$ROOT/.zig-cache/job-runner-smoke"
rm -rf "$OUT"
mkdir -p "$OUT/ws"

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

note "valid fixture through native --once"
./zig-out/bin/boris-job-runner --once \
  --boris ./zig-out/bin/boris \
  --archive "$OUT/valid.tar" \
  --result-json "$OUT/valid.json" \
  --work-root "$OUT/ws"
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
pass "valid fixture compiled"

note "poisoned fixture through native --once"
set +e
./zig-out/bin/boris-job-runner --once \
  --boris ./zig-out/bin/boris \
  --archive "$OUT/poisoned.tar" \
  --result-json "$OUT/poisoned.json" \
  --work-root "$OUT/ws"
poisoned_rc=$?
set -e
[[ "$poisoned_rc" -eq 1 ]] || fail "poisoned job exited $poisoned_rc, expected 1"
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

note "job-runner smoke complete"
