---
title: "`tools/migration-lab/build.zig` review state"
id: docs/tools/migration-lab/build/review-state
parent: docs/tools/migration-lab/build
status: draft
tags: [boris, zig, tools, review-state, migration-lab, build]
---

# `tools/migration-lab/build.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **`build.zig` source not read directly:** The exact build declarations (`addExecutable`, `addRunArtifact`, `addTest`, any `addOption`) should be inspected and documented. Relevant because build options affect reproducibility and target handling. *Confirmed need; smallest follow-up: read and document the file's 1,238 bytes.*
- **`build.zig.zon` not inspected:** Confirm whether external dependencies exist or whether the package is standard-library-only. *Confirmed need; uncertain impact.*
- **Per-mode cleanup contracts:** Document which modes wipe previous output and which do not. Currently only WordPress is documented as performing cleanup. *Confirmed gap; uncertain whether other modes document this.*
- **Schema changelog:** `CHANGELOG.md` for the tool (if it exists) should be inspected to understand schema evolution history for WordPress v3 and any prior breaking changes. *Likely useful; uncertain existence.*


### Test follow-up

- **Two-run byte-comparison tests for non-Astro modes:** WordPress, Instagram, Obsidian, Notion, Filed, Starlight, asset-filename, link-audit, and frontmatter-review modes lack explicit determinism tests. *Confirmed gap; matters for reproducibility claims.*
- **Instagram test leak fix:** Instagram in-module tests are excluded from aggregated test binary due to arena leak under testing allocator. Fixing this would restore full coverage. *Confirmed gap; noted in source.*
- **Path safety tests for all modes:** Only Astro, theme-archaeology, WordPress (media), Instagram, and asset-filename have explicit traversal/immutability tests. Other modes lack path-safety test coverage. *Confirmed gap.*
- **`--out` equals `--input` tests at integration level:** Only parsed at CLI layer; no integration test verifies the exit-2 behavior end-to-end. *Likely useful.*
- **Allocation-failure tests:** No OOM path is covered. *Uncertain necessity given arena model, but worth noting.*
- **Large-file / high-cardinality tests:** No resource-exhaustion boundary is tested. *Uncertain.*


### Implementation follow-up

- **Uniform stale-output cleanup:** If modes other than WordPress do not wipe previous output before re-writing, stale artifacts from a prior run could persist. Evidence is insufficient to confirm this as a defect; worth verifying per-mode. *Uncertain.*
- **Centralized traversal check:** `hasTraversal` and media-URI rejection logic exist in multiple modules. A shared utility would reduce the risk of inconsistent coverage in future modes. *Likely; not a confirmed defect.*
- **Fence-safety in non-Instagram modes:** Instagram documents and implements backtick-run fence sizing. Whether other modes producing Markdown from foreign bytes (e.g., Obsidian, Notion) apply equivalent protection is uncertain. *Uncertain; worth inspecting.*

***
