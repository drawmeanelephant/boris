#!/usr/bin/env bash
# Build static ApexMarkdown (libapex.a + cmark-gfm) for Boris Feature 1.
# Invoked from build.zig (Strategy A). User entrypoint remains `zig build`.
#
# Residual mitigations:
#   D2 — never link system libyaml (product does not feed YAML metadata into Apex)
#   D3 — stamp + archive freshness skip so `zig build` does not re-run cmake when idle
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/vendor/apex-markdown"
BUILD="${ROOT}/vendor/apex-markdown/build"
# Bump when configure policy changes (forces reconfigure + rebuild).
POLICY_VERSION="boris-apex-policy-2-no-system-libyaml"
STAMP="${BUILD}/.boris-apex-stamp"
FORCE="${BORIS_FORCE_APEX_BUILD:-0}"

LIBS=(
  "${BUILD}/libapex.a"
  "${BUILD}/vendor/cmark-gfm/src/libcmark-gfm.a"
  "${BUILD}/vendor/cmark-gfm/extensions/libcmark-gfm-extensions.a"
)

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

need_build=0
need_reconfigure=0

if [[ "${FORCE}" == "1" ]]; then
  need_build=1
  need_reconfigure=1
fi

for f in "${LIBS[@]}"; do
  if [[ ! -f "${f}" ]]; then
    need_build=1
    break
  fi
done

stamp_policy=""
if [[ -f "${STAMP}" ]]; then
  stamp_policy="$(head -n1 "${STAMP}" 2>/dev/null || true)"
fi

if [[ "${need_build}" -eq 0 ]]; then
  if [[ ! -f "${STAMP}" ]] || [[ "${stamp_policy}" != "${POLICY_VERSION}" ]]; then
    # Missing or stale stamp: rebuild and reconfigure so D2 cmake flags apply.
    need_build=1
    need_reconfigure=1
  elif [[ "${SRC}/CMakeLists.txt" -nt "${STAMP}" ]] || \
       [[ "${ROOT}/scripts/build-apex-markdown.sh" -nt "${STAMP}" ]]; then
    need_build=1
    need_reconfigure=1
  fi
elif [[ ! -f "${STAMP}" ]] || [[ "${stamp_policy}" != "${POLICY_VERSION}" ]]; then
  need_reconfigure=1
fi

# D2: existing caches that linked system libyaml must reconfigure.
if [[ -f "${BUILD}/CMakeCache.txt" ]]; then
  if grep -Eq 'APEX_HAVE_LIBYAML|YAML_FOUND:INTERNAL=1|YAML_LIBRARIES:INTERNAL=.+' \
       "${BUILD}/CMakeCache.txt" 2>/dev/null; then
    echo "build-apex-markdown: dropping cache that saw system libyaml (D2 policy)"
    need_reconfigure=1
    need_build=1
  fi
fi

if [[ "${need_build}" -eq 0 ]]; then
  # Fast path (D3): archives + stamp current — skip cmake entirely.
  exit 0
fi

if [[ "${need_reconfigure}" -eq 1 ]]; then
  echo "build-apex-markdown: reconfigure required (policy=${POLICY_VERSION})"
  rm -rf "${BUILD}"
fi

jobs="$(
  if command -v nproc >/dev/null 2>&1; then nproc
  elif command -v sysctl >/dev/null 2>&1; then sysctl -n hw.ncpu
  else echo 4
  fi
)"

mkdir -p "${BUILD}"

if [[ ! -f "${BUILD}/CMakeCache.txt" ]]; then
  echo "build-apex-markdown: configuring ${BUILD} (policy=${POLICY_VERSION})"
  # D2: hide pkg-config and cmake yaml package discovery so host libyaml is never
  # linked. Product frontmatter is Boris-owned; Apex is not fed YAML metadata options.
  # Empty pkg-config executable + disable find_package(yaml) keeps builds deterministic.
  cmake -S "${SRC}" -B "${BUILD}" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMARK_TESTS=OFF \
    -DCMARK_STATIC=ON \
    -DCMARK_SHARED=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_DISABLE_FIND_PACKAGE_yaml=ON \
    -DCMAKE_DISABLE_FIND_PACKAGE_PkgConfig=ON
fi

echo "build-apex-markdown: building apex_static (-j${jobs})"
cmake --build "${BUILD}" --target apex_static -j"${jobs}"

for f in "${LIBS[@]}"; do
  if [[ ! -f "${f}" ]]; then
    echo "error: expected static library missing: ${f}" >&2
    exit 1
  fi
done

# Confirm D2: configured tree must not enable libyaml.
if [[ -f "${BUILD}/CMakeCache.txt" ]] && \
   grep -Eq 'APEX_HAVE_LIBYAML|YAML_FOUND:INTERNAL=1' "${BUILD}/CMakeCache.txt" 2>/dev/null; then
  echo "error: Apex build unexpectedly enabled libyaml (D2 policy violated)" >&2
  exit 1
fi

{
  echo "${POLICY_VERSION}"
  date -u +"%Y-%m-%dT%H:%M:%SZ"
} >"${STAMP}"

echo "build-apex-markdown: ok"
