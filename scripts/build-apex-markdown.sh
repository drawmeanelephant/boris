#!/usr/bin/env bash
# Build static ApexMarkdown (libapex.a + cmark-gfm) for Boris Feature 1.
# Invoked from build.zig (Strategy A). User entrypoint remains `zig build`.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/vendor/apex-markdown"
BUILD="${ROOT}/vendor/apex-markdown/build"

if ! command -v cmake >/dev/null 2>&1; then
  cat >&2 <<'EOF'
error: cmake is required to build vendored ApexMarkdown (Feature 1).

Install CMake (compile-time host tool only; not a runtime dependency), then re-run:
  zig build

  macOS:  brew install cmake
  Debian: sudo apt-get install cmake
  Fedora: sudo dnf install cmake
EOF
  exit 1
fi

if [[ ! -f "${SRC}/CMakeLists.txt" ]]; then
  echo "error: missing ${SRC}/CMakeLists.txt (ApexMarkdown pin)" >&2
  exit 1
fi

jobs="$(
  if command -v nproc >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu
  else echo 4
  fi
)"

if [[ ! -f "${BUILD}/CMakeCache.txt" ]]; then
  echo "build-apex-markdown: configuring ${BUILD}"
  cmake -S "${SRC}" -B "${BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMARK_TESTS=OFF \
    -DCMARK_STATIC=ON \
    -DCMARK_SHARED=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
fi

echo "build-apex-markdown: building apex_static (-j${jobs})"
cmake --build "${BUILD}" --target apex_static -j"${jobs}"

# Expected archives (paths used by build.zig linkApex)
for f in \
  "${BUILD}/libapex.a" \
  "${BUILD}/vendor/cmark-gfm/src/libcmark-gfm.a" \
  "${BUILD}/vendor/cmark-gfm/extensions/libcmark-gfm-extensions.a"
do
  if [[ ! -f "${f}" ]]; then
    echo "error: expected static library missing: ${f}" >&2
    exit 1
  fi
done

echo "build-apex-markdown: ok"
