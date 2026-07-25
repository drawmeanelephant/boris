---
title: "`tools/migration-lab/link_audit.zig` evidence and cases"
id: docs/tools/migration-lab/link_audit/evidence-and-cases
parent: docs/tools/migration-lab/link_audit
status: draft
tags: [boris, zig, tools, evidence, migration-lab, link_audit]
---

# `tools/migration-lab/link_audit.zig` evidence and cases

## Operational walkthroughs

### Default link-audit execution

**Invocation:**

```
zig build run -- --mode link-audit --root ./zig-out/site --out ./link-report
```

**Inputs:**
`./zig-out/site` — a generated static HTML tree (produced by `boris`), read-only. `--out ./link-report` specifies the report directory.

**Execution path:**
`main` → `parseOptions` → root/out equality check → `linkaudit.run(io, gpa, { .rootdir = "./zig-out/site", .outdir = "./link-report", .quiet = false })`. Internal execution path within `linkaudit.zig` is uncertain from available evidence.

**Outputs:**
`./link-report/linkaudit.json` and `./link-report/REPORT.md`. Content structure uncertain.

**Deterministic properties:**
Unknown. The module likely follows the migration-lab pattern of deterministic file ordering and stable output, but no run-twice test for this mode has been confirmed.

**Failure behavior:**
Any `!void` error propagated out of `linkaudit.run` is caught in `main.zig`, which emits `"migration-lab link-audit failed: &lt;ErrorName>"` to stderr and returns exit code 3.

**Evidence strength:** Documented contract (dispatch path) — structurally checked at `main.zig` level; behavior inside `linkaudit.zig` is uncertain.

**Residual gap:** The full internal execution path, discovery algorithm, link extraction logic, fragment resolution, JSON schema, and ordering guarantees all require direct inspection of `linkaudit.zig`.

***

### Help / usage

**Invocation:** `zig build run -- --help` or `zig build run -- -h`

**Inputs:** No filesystem access.

**Execution path:** `main` → `parseOptions` sets `opts.help = true` → `printUsage()` → exit 0.

**Outputs:** The usage text to stderr. The link-audit section reads:

```
audit  generated-output validation
  --mode=link-audit   Scan static HTML output for missing local routes/fragments
    --root=DIR          Generated HTML tree (required; never modified)
    --out=DIR           Output directory (default: migration-report)
    Writes linkaudit.json, REPORT.md
    External, mailto, tel, data, and hash-only links are not audited.
```

**Evidence strength:** Directly demonstrated (usage string in `main.zig` source).

**Residual gap:** None for this path.

***

### Invalid CLI invocation

**Invocation examples:**

- `zig build run -- --mode link-audit` (missing `--root`, defaults to `.`)
- `zig build run -- --mode link-audit --root ./site --out ./site` (root equals out)
- `zig build run -- --mode link-audit --foo` (unknown flag)

**Failure behavior:**

- Missing `--root` is **not** detected as an error (defaults to `.`); the tool will attempt to walk the current directory.
- Root equals out: `main.zig` emits `"--out must differ from --root"` to stderr, returns exit 2.
- Unknown flag: `parseOptions` returns `error.UnknownFlag`; `main.zig` emits `"unknown argument, try --help"` and returns exit 2.

**Evidence strength:** Structurally checked (code visible in `main.zig`).

**Residual gap:** The defaulting behavior of `--root` to `.` for link-audit mode may be unintentional — other modes that require a specific directory explicitly check for `null`. Since `rootdir` is a non-optional `[]const u8` field defaulting to `"."`, there is no mandatory-argument enforcement for `--root` in link-audit mode.

***

## Control flow

```text
process entry (main.zig: main)
    → initialize arena + gpa allocators, I/O via std.process.Init
    → collect process args into ArrayList
    → parseOptions → opts.mode = .linkaudit (if --mode link-audit/links/output-audit)
    → on parse error → stderr + exit 2
    → if opts.help → printUsage + exit 0
    → switch opts.mode → .linkaudit branch
        → check opts.rootdir != opts.outdir
            → if equal → stderr + exit 2
        → linkaudit.run(io, gpa, { rootdir, outdir, quiet })
            [inside linkaudit.zig — uncertain from available evidence:]
            → create/open outdir
            → walk rootdir HTML tree, collect routes
            → extract local links and fragment refs from each HTML file
            → resolve each link against collected routes/fragments
            → classify: found / missing / external-skipped
            → emit linkaudit.json
            → emit REPORT.md
            → if quiet=false, print summary
        → on error → std.log.err("migration-lab link-audit failed: ...") + exit 3
    → exit 0
```

Stages inside `linkaudit.run` are inferred from stated purpose and cross-module pattern. They are not directly confirmed.

***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test parseOptions link-audit flags` | **Absent** | — | — | Mode alias resolution, `--root`/`--out` forwarding for link-audit |
| Inline tests in `linkaudit.zig` (via `refAllDecls`) | Unknown | Unknown | Uncertain | Full scope unknown |
| `refAllDecls`-style import (`test { _ = linkaudit; }`) | Module-level compilation check | Module compiles cleanly | Structurally checked | No behavioral property |
| Fixture integration test (comparable to `astro fixture scan produces stable report sections`) | **Not confirmed** | — | — | Round-trip determinism, source immutability, fixture output shape |

The absence of a `parseOptions link-audit flags` test is notable: every other mode (`astro`, `wordpress`, `instagram`, `obsidian`, `notion`, `filed`, `asset-filename`, `theme-archaeology`, `wordpress-theme`, `starlight`, `frontmatter-review`) has an explicit test block in `main.zig` verifying mode alias resolution and option forwarding. Link-audit does not.

***
