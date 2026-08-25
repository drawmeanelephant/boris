#!/bin/sh
# Copy the ReleaseSmall compileBundle module next to the Worker entry.
set -eu
root=$(CDPATH= cd -- "$(dirname "$0")/../.." && pwd)
src="$root/zig-out/bin/boris-embed-small.wasm"
dst="$(CDPATH= cd -- "$(dirname "$0")" && pwd)/src/boris-embed-small.wasm"
if [ ! -f "$src" ]; then
  echo "missing $src — run: zig build" >&2
  exit 1
fi
cp "$src" "$dst"
echo "copied $src -> $dst"
