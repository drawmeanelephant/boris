# Vendored ApexMarkdown/apex (Boris pin)

This directory is a **source snapshot** of the real Apex Markdown processor,
owned by Boris for offline / reproducible builds. It is **not** the Boris host
ABI (`vendor/apex/apex.h`). Campaign archive:
[`archive/docs/reviews/feature-1-apex-fidelity-spec.md`](../../archive/docs/reviews/feature-1-apex-fidelity-spec.md).

| Field | Value |
|-------|--------|
| **Upstream** | https://github.com/ApexMarkdown/apex |
| **Release tag** | `v1.1.13` |
| **Upstream tag object** | `0a2fb339a7675b80053eda75bb8def5efb2e7d83` |
| **Upstream commit** | `8d70820cdfc2f32c2f11d8020f8a66268cd064ff` |
| **VERSION file** | `1.1.13` |
| **License** | MIT (`LICENSE`) — Copyright (c) 2026 Brett Terpstra |
| **Pinned for Boris** | 2026-07-21 (ApexMarkdown v1.1.13 upgrade) |
| **Product role** | Static libs linked; host `apex_render` is Unified adapter (Chat 3) |

## Nested upstream dependencies (snapshot SHAs)

| Path | Upstream | Commit (at pin) |
|------|----------|-----------------|
| `vendor/cmark-gfm/` | https://github.com/github/cmark-gfm | `587a12bb54d95ac37241377e6ddc93ea0e45439b` |
| `vendor/libyaml/` | https://github.com/yaml/libyaml | `840b65c40675e2d06bf40405ad3f12dec7f35923` |

Nested `.git` metadata was **removed** so this tree is a flat Boris-owned
snapshot (no network required after clone of boris). cmark-gfm is Apex’s
engine substrate only — **not** Boris’s public Markdown product surface.

## Boris-local patches

The v1.1.13 source tree is otherwise an upstream snapshot. Boris retains these
local files/policies:

| Path | Patch | Reason |
|------|-------|--------|
| `.gitignore` | Do not blanket-ignore `*.cmake`; retain vendored CMake modules | Fresh offline/CI configure must include cmark-gfm’s source modules |
| `VENDOR.md` | Boris provenance, build policy, and adapter notes | Reproducible vendoring record |

The host ABI and adapter remain in `vendor/apex/`; they are Boris code and are
not part of the upstream snapshot.

## What is not committed

| Path / pattern | Reason |
|----------------|--------|
| `build/` | CMake output; regenerated at compile time |
| `*.a` / `*.o` | Repo-root `.gitignore`; never commit prebuilt archives |
| Nested `.git` | Snapshot ownership; pin recorded in this file |

## How Boris builds this (Strategy A — Chat 2+)

User entrypoint remains **`zig build`**. Feature 1 links **static** archives
produced as a compile-time sub-step:

1. Host tool: **CMake** — build-time only, not a runtime dep.
2. `scripts/build-apex-markdown.sh` configures/builds `apex_static` into
   `vendor/apex-markdown/build/` (gitignored).
3. `build.zig` `linkApex` adds:
   - `build/libapex.a`
   - `build/vendor/cmark-gfm/extensions/libcmark-gfm-extensions.a`
   - `build/vendor/cmark-gfm/src/libcmark-gfm.a`
4. Manual: `zig build build-apex`
5. Host adapter `vendor/apex/apex.c` calls
   `apex_markdown_to_html` + copy + `apex_free_string` (Chat 3).
6. Zig continues to `@cImport` **only** Boris host `vendor/apex/apex.h`
   (host include guard: `BORIS_APEX_HOST_H`, not upstream `APEX_H`).
7. Hostile path (`test-apex-hostile`) does **not** link ApexMarkdown.

### Boris build policy (D2 / D3)

| ID | Policy |
|----|--------|
| **D2** | Configure **without** system libyaml (`CMAKE_DISABLE_FIND_PACKAGE_yaml`, PkgConfig off). Product frontmatter is Boris-owned; Apex is not fed YAML metadata options. Host libyaml must not change link or behavior. Nested `vendor/libyaml/` remains in the snapshot for upstream parity but is **not** linked by the Boris product path. |
| **D3** | Script writes `build/.boris-apex-stamp`. When stamp policy + archives are current and `CMakeLists.txt` / the script are not newer, the script exits 0 without invoking cmake (fast path under every `zig build`). Force: `BORIS_FORCE_APEX_BUILD=1`. |

## Modes (product default)

Boris product default is **`APEX_MODE_UNIFIED`** (see upstream
[Modes wiki](https://github.com/ApexMarkdown/apex/wiki/Modes)). Other modes are
not exposed on the CLI in Feature 1.

## Refreshing the pin

1. Replace this tree with a clean checkout of the desired tag + submodules.
2. Record new tag/commit/submodule SHAs in this file.
3. Delete nested `.git` and any `build/` artifacts before committing.
4. Re-run Feature 1 gates after adapter/link changes.
