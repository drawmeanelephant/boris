---
title: "`tools/migration-lab/link_audit.zig` overview"
id: docs/tools/migration-lab/link_audit
status: draft
tags: [boris, zig, tools, migration-lab, link_audit]
---

# `tools/migration-lab/link_audit.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/tools/migration-lab/link_audit/surface-and-execution|Surface and execution]]
* [[docs/tools/migration-lab/link_audit/evidence-and-cases|Evidence and cases]]
* [[docs/tools/migration-lab/link_audit/review-state|Review state]]

## Executive summary

`tools/migration-lab/link_audit.zig` is one of thirteen mode-implementation modules compiled into the `boris-migration-lab` standalone developer tool. It is imported by `tools/migration-lab/main.zig` as `const linkaudit = @import("linkaudit.zig");` and activated when the user passes `--mode link-audit` (aliases: `links`, `output-audit`). The module is not part of the Boris product binary, is not on the Boris compiler runtime path, and does not interact with Boris's content pipeline, JSON IR, frontmatter system, Context Bundles, or any source-RAG tooling.

The tool's function is post-publication audit: given a tree of already-generated static HTML (`--root`), it walks the tree looking for local hyperlinks and fragment references that point to routes or anchors that do not exist in the generated output. It writes two machine-readable and human-readable report files—`linkaudit.json` and `REPORT.md`—into the separately-specified `--out` directory. The `--root` directory (the HTML output tree) is never modified. External links, `mailto:`, `tel:`, `data:`, and hash-only links are explicitly excluded from the audit scope.

The file is purely an implementation module; the executable entry point, argument parser, allocator setup, I/O wiring, mode dispatch, exit-code mapping, and the full CLI surface for all thirteen modes live in `main.zig`. `link_audit.zig` exports a single public `run(io, gpa, opts)` function that receives a pre-parsed options struct containing `rootdir`, `outdir`, and `quiet`. The boundary between entry point and mode implementation is clean: `main.zig` validates that `--root` and `--out` differ before calling `linkaudit.run`.

The executable is compiled only from `tools/migration-lab/build.zig` and its root build integration. It has no dependency on any Boris product source file and shares no implementation code with the Boris compiler. The tool relies solely on the Zig standard library. It does not access the network, does not invoke subprocesses, and does not write into its input tree.

Test coverage evidence visible in `main.zig` does not include a dedicated `test parseOptions link-audit flags` block, unlike the blocks present for all other modes. The `refAllDecls` declaration at the bottom of `main.zig` pulls in tests declared inside the imported mode modules, so any inline tests inside `linkaudit.zig` itself are included in the test binary, but their content and scope are inaccessible from the available evidence. Whether a fixture-level integration test for link-audit exists—comparable to the astro fixture scan, wordpress decode-entities, or obsidian/notion unit tests—cannot be confirmed from currently available source bundles.

***

## Classification

| Property | Assessment |
| :-- | :-- |
| Primary classification | Developer-tool mode implementation module |
| Conceptual domain | Generated-output audit / link integrity verification |
| Tool family | `boris-migration-lab` (standalone, separate from Boris product binary) |
| Build root | `tools/migration-lab/build.zig` |
| Executable or module name | `boris-migration-lab` (no separate per-mode binary) |
| Product runtime dependency | None; not linked into the `boris` product binary |
| Root build integration | Exposed via root `build.zig` as a convenience step (build file evidence; exact step name unconfirmed from available source) |
| Expected execution commands | `zig build run -- --mode link-audit --root <html-tree> --out <report-dir>` (from `tools/migration-lab/`) |
| Input authority | User-supplied generated HTML tree (read-only) |
| Output ownership | All writes go to the `--out` directory; `linkaudit.json` and `REPORT.md` |
| Network or subprocess use | None documented; none visible in call site in `main.zig` |
| Main collaborators | `tools/migration-lab/main.zig` (entry point, CLI, dispatch); Zig standard library |
| Documentation depth warranted | Medium — single-mode implementation module with one public entry point |


***

## Role in the Boris architecture

`link_audit.zig` is entirely outside the Boris product compilation and publication pipeline. The Boris product compiler reads Zig source, parses content, and emits HTML and JSON IR. `link_audit.zig` consumes _already-emitted_ HTML—i.e., it is a post-publication consumer of the compiler's output, not a participant in producing it.

Within the `tools/migration-lab/` family, the file occupies the same structural position as `archaeology.zig`, `wordpress.zig`, `obsidian.zig`, and the other eleven mode modules: it is a single-file implementation imported by `main.zig`, compiled into one shared `boris-migration-lab` executable, and activated by a mode switch. The migration-lab executable is built from `tools/migration-lab/build.zig`, which is independent of the Boris product build graph except where the root `build.zig` wires in a convenience invocation step.

The file has no relationship to the source-RAG tool under `tools/source-rag/`. It does not read source-RAG bundles, does not produce source-RAG artifacts, and is not referenced from any source-RAG build path. It is also unrelated to the documentation observatory, Context Bundles, and product content RAG.

The link-audit mode's natural position in a developer workflow is after `boris` has published a site: a developer runs `boris` to produce a static HTML tree, then runs `boris-migration-lab --mode link-audit --root <published-dir> --out <audit-dir>` to verify that no internal links or fragment anchors are dangling before the site is deployed or reviewed. The outputs (`linkaudit.json`, `REPORT.md`) are human and machine review artifacts; they are not consumed back by Boris.

The module is:

- **Not** linked into the Boris product binary
- **Compiled** as part of the `boris-migration-lab` separate executable
- **Not** imported by any other tool module (based on available evidence)
- **Not** used as a test root independently
- Exposed through the migration-lab `build.zig` and (likely) a root convenience step

***

## Tool boundary and non-goals

**What the tool is allowed to inspect:** The user-specified `--root` directory, which is expected to be a fully-generated static HTML tree. The module reads HTML files in order to extract local `href` and fragment references and to enumerate routes present in the output. No Boris source files, content Markdown, frontmatter, or compiler intermediate representations are read.

**What it is allowed to write:** Only the `--out` directory. `main.zig` structurally enforces that `--root` and `--out` are not the same path before dispatching to `linkaudit.run`; any string-identity overlap returns exit code 2 before the module is called. Within `--out`, the module writes `linkaudit.json` and `REPORT.md`.

**Does not modify tracked source files:** The usage text states "never modified" for `--root`. This is a documented intention; whether the implementation further enforces it (e.g., opens the root directory read-only) is uncertain from available evidence.

**Does not change compiler behavior:** The module has no path back into the Boris compiler. It reads only generated HTML and writes only its own report directory.

**Does not change product frontmatter or IR:** Correct. The module operates entirely on HTML; it does not parse or emit frontmatter YAML or Boris JSON IR.

**Does not perform semantic interpretation:** The module audits link targets structurally—whether a route or fragment exists—not whether the linked content is semantically correct or documentation-complete.

**Does not evaluate documentation correctness:** Explicitly not in scope. Broken links in the audit sense means a missing file or missing `id=` anchor, not a conceptual gap in documentation.

**Does not invoke an LLM:** No.

**Does not upload data:** No.

**Does not access the network:** The usage text explicitly states "External, mailto, tel, data, and hash-only links are not audited," which implies network access is absent by design. Whether this is structurally enforced (e.g., no `std.net` calls) cannot be confirmed from available evidence but is consistent with the tool's architecture.

**Does not act as a migration tool:** The link-audit mode is an audit/validation mode, not a content migration or conversion mode. It does not produce Boris-ready Markdown or migration manifests.

**Is not part of the ordinary `boris` execution path:** Correct. The tool is invoked by a developer separately, after Boris has published output.

The boundary between _implemented enforcement_ and _documented intention_ for the read-only constraint on `--root` remains uncertain without inspecting `linkaudit.zig` directly.

***

## Build and invocation model

`link_audit.zig` is not compiled independently. It is an `@import`-ed module within `tools/migration-lab/main.zig`, compiled as part of the `boris-migration-lab` executable defined in `tools/migration-lab/build.zig`. There is no per-mode binary.

The standalone build declaration lives in `tools/migration-lab/build.zig`. The root `build.zig` likely exposes a convenience step (exact step name unconfirmed from available evidence; referenced as a convenience integration in the broader repository pattern). The module shares the same target and optimization handling as the rest of the `boris-migration-lab` executable.

Imported modules from `main.zig` perspective:

- `@import("linkaudit.zig")` → bound as `linkaudit`
- All other mode modules are imported at the same level; none of them re-import `linkaudit.zig`

The test binary for the migration lab (`zig build test` from `tools/migration-lab/`) includes a top-level `test { _ = linkaudit; }` via the `refAllDecls`-style block, pulling any inline tests from `linkaudit.zig` into the test executable.

### Command table

| Command | Purpose | Inputs | Outputs | Notes |
| :-- | :-- | :-- | :-- | :-- |
| `zig build run -- --mode link-audit --root <html-dir> --out <report-dir>` | Run link-audit against a generated HTML tree | `<html-dir>` (read-only) | `<report-dir>/linkaudit.json`, `<report-dir>/REPORT.md` | From `tools/migration-lab/`; `--root` and `--out` must differ |
| `zig build run -- --mode links --root <html-dir> --out <report-dir>` | Same as above via alias `links` | Same | Same | Alias confirmed in `Mode.parse` |
| `zig build run -- --mode output-audit --root <html-dir> --out <report-dir>` | Same as above via alias `output-audit` | Same | Same | Alias confirmed in `Mode.parse` |
| `zig build test` | Build and run all migration-lab tests including any inline tests in `linkaudit.zig` | Source and fixtures | Test pass/fail | From `tools/migration-lab/` |
| `zig build --build-file tools/migration-lab/build.zig` | Build `boris-migration-lab` from repo root | All mode modules | `zig-out/bin/boris-migration-lab` | Root convenience path |


***
