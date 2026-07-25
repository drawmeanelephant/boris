---
title: "`tools/migration-lab/link_audit.zig` review state"
id: docs/tools/migration-lab/link_audit/review-state
parent: docs/tools/migration-lab/link_audit
status: draft
tags: [boris, zig, tools, review-state, migration-lab, link_audit]
---

# `tools/migration-lab/link_audit.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **Missing schema documentation:** The `linkaudit.json` format has no documented schema identifier, field inventory, or version. Given the repository pattern, a `pub const formatid` and `pub const schemaversion` likely exist in `linkaudit.zig` but are not confirmed. Adding a schema reference document (or at minimum documenting the fields in the README or tool usage text) would make the output consumable by external tooling with confidence. — *Need: likely; gap matters for downstream CI use.*
- **Mandatory `--root` behavior:** The usage text says `--root=DIR` is "required; never modified," but the implementation defaults to `.` without an error. A note in the usage text clarifying the default behavior (or changing it to an error) would align documentation with implementation. — *Need: confirmed gap.*
- **Mode aliases undocumented in usage help:** The aliases `links` and `output-audit` are implemented in `Mode.parse` but do not appear in the `printUsage` output block for `link-audit` (unlike `obsidian`'s "Aliases: obs vault" pattern). — *Need: likely; evidence from usage text inspection.*


### Test follow-up

- **Missing `parseOptions link-audit flags` test:** Every other mode has an explicit test verifying alias resolution and field forwarding. Link-audit has none. Adding `test "parseOptions link-audit flags"` with assertions for `link-audit`, `links`, and `output-audit` aliases, `rootdir` and `outdir` forwarding, and the `--root == --out` rejection would bring link-audit to parity. — *Need: confirmed; evidence: absence in `main.zig`.*
- **Missing fixture integration test:** A test comparable to `"astro fixture scan produces stable report sections"` would verify round-trip determinism, source immutability, and JSON output shape against a `fixtures/mini-link-audit` HTML tree. Without it, the module's behavioral contract is untested at the integration level. — *Need: confirmed gap.*
- **Run-twice determinism test:** The pattern of running twice and comparing byte-for-byte output is present for astro and theme-materialize. A link-audit equivalent would confirm output stability. — *Need: likely.*
- **Path traversal test:** A fixture containing `href="../../outside"` would verify whether the route resolution step refuses or safely handles traversal-containing link targets. — *Need: likely.*
- **Empty HTML tree test:** Verifying behavior when `--root` contains no `.html` files (zero routes discovered). — *Need: uncertain.*


### Implementation follow-up

- **Explicit `--root` required-argument check:** If the intent is that `--root` is required for `link-audit`, adding an explicit check (`if (std.mem.eql(u8, opts.rootdir, "."))` or converting `rootdir` to an optional for this mode) would prevent silent auditing of the current working directory. — *Need: likely; evidence: documented as "required" in usage text but not enforced.*
- **Alias documentation in `printUsage`:** Adding `Aliases: links output-audit` to the `link-audit` usage block would align with the `obsidian`, `wordpress`, `notion`, and other blocks that document their aliases. — *Need: confirmed gap.*

***
