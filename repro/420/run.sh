#!/usr/bin/env bash
# Standalone repro for drawmeanelephant/boris#420.
# Builds the harness against boris's own src/publication_touches.zig (the
# checked-out revision in this worktree, 30805ab8) and runs it.
set -euo pipefail
cd "$(dirname "$0")"
zig build
./zig-out/bin/repro-420
