---
title: "`tools/migration-lab/link_audit.zig` surface and execution"
id: docs/tools/migration-lab/link_audit/surface-and-execution
parent: docs/tools/migration-lab/link_audit
status: draft
tags: [boris, zig, tools, surface, migration-lab, link_audit]
---

# `tools/migration-lab/link_audit.zig` surface and execution

## CLI surface

The full CLI is parsed in `main.zig`; `link_audit.zig` receives a pre-parsed options struct. The flags relevant to `link-audit` mode are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode link-audit` | Yes (or use alias) | `astro` | `link-audit`, `links`, `output-audit` | Selects link-audit mode | Unrecognised value → `error.InvalidValue` → exit 2 |
| `--root &lt;DIR>` | Yes (for link-audit) | `.` | Any non-empty string | Path to generated HTML tree to audit; never modified | If equal to `--out` → usage error, exit 2 |
| `--out &lt;DIR>` | No | `migration-report` | Any non-empty string | Report output directory; created if missing | If equal to `--root` → usage error, exit 2 |
| `-q` / `--quiet` | No | `false` | flag (no value) | Suppress progress output | N/A |
| `-h` / `--help` | No | `false` | flag (no value) | Print usage text and exit 0 | N/A |

**Notes on scope:**

- `--wxr`, `--media`, `--dump`, `--vault`, `--export`, `--filed-root`, `--locale`, `--max-pages`, `--boris`, `--ledger`, `--content` are all parsed by `main.zig` but not forwarded to `linkaudit.run`. Passing them together with `--mode link-audit` would be silently accepted at the CLI level (they would not trigger `UnknownFlag`), but they would have no effect on the link-audit execution path.
- Exact exit codes: `0` (success), `2` (usage error), `3` (IO error). These are defined as `ExitCode.success`, `ExitCode.usage`, `ExitCode.ioerror` in `main.zig`.
- `--root` absence does not cause an explicit error for link-audit: because `rootdir` defaults to `.` for all modes, a missing `--root` would cause the tool to attempt to audit the current working directory. This differs from modes like `wordpress` where the required argument is an optional field that is explicitly checked.

***

## Inputs and discovery model

| Input category | Discovery rule | Included by default | Exclusions | Evidence |
| :-- | :-- | :-- | :-- | :-- |
| Generated HTML tree | `--root` argument (defaults to `.`) | All `.html` files discovered by walking `--root` | Directories/files outside `--root`; symlink policy uncertain | Usage text: "Scan static HTML output for missing local routes/fragments" |
| Local `href` targets | Extracted from `<a href=...>` in HTML files | Internal (relative and absolute-path) links | External (`http://`, `https://`), `mailto:`, `tel:`, `data:`, hash-only (`#fragment`) | Usage text explicitly states these are not audited |
| Fragment anchors | `id=` attributes or anchor names in HTML files | All anchors within scanned HTML | Unknown — exact extraction logic requires inspecting `linkaudit.zig` directly |  |
| Route existence | File presence in `--root` tree for target paths | All `.html` routes present in `--root` | Unknown — index file resolution (`index.html` for directory routes) behavior uncertain |  |

The discovery logic, path normalization, ordering guarantees, symlink handling, and behavior on unreadable files all reside within `linkaudit.zig` and are inaccessible from available evidence in the source bundles. The above reflects what is structurally implied by the tool's stated purpose and usage text.

***

## Output artifact model

| Artifact | Format | Ownership | Ordering guarantee | Consumer | Stability |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `linkaudit.json` | JSON (format identifier uncertain; likely follows the `boris-*-migration-lab` pattern with `format`, `schemaVersion`, `toolVersion` fields) | Owned by `--out` directory | Unknown | Machine consumers, LLM review, CI scripts | Unknown; no versioning evidence available from current bundles |
| `REPORT.md` | Markdown human-readable report | Owned by `--out` directory | Unknown | Human reviewer | Unknown |

Whether `linkaudit.json` follows the same schema pattern (`format`, `schemaVersion`, `toolVersion`, arrays of findings) as `wordpress.zig` (`schemaversion: 3`, `toolversion: 0.4.1`) and `themematerialize.zig` (`schemaversion: 1`) is strongly implied by the repository-wide convention but cannot be confirmed without inspecting `linkaudit.zig` directly.

Stale-output handling (whether a previous `--out` directory is cleaned before writing) follows the pattern visible in other modes (e.g., `wordpress.zig` performs a deterministic `lab-owned out wipe on re-run`), but whether `linkaudit.zig` does the same is uncertain.

***

## Serialization and schema behavior

| Format or file | Identifier or schema version | Producer | Ordering | Validation coverage |
| :-- | :-- | :-- | :-- | :-- |
| `linkaudit.json` | Unknown — not confirmed from available evidence | `linkaudit.zig` | Unknown | Unknown |
| `REPORT.md` | N/A (Markdown prose) | `linkaudit.zig` | Unknown | Unknown |

The `boris-migration-lab` convention visible in other modules (e.g., `pub const formatid = "boris-wordpress-migration-lab"`, `pub const schemaversion: u32 = 3`) is likely followed in `linkaudit.zig`, but this cannot be stated as confirmed from the available source bundles.

***

## Determinism and reproducibility

| Property | Mechanism | Evidence strength | Residual limitation |
| :-- | :-- | :-- | :-- |
| Stable output across two runs on same input | Multiple modes in the migration lab demonstrate byte-for-byte determinism via run-twice-compare tests | Documented contract (pattern); uncertain for `linkaudit` specifically | No run-twice comparison test for link-audit is confirmed from available evidence |
| File discovery order | Other modes use explicit sorting (e.g., `std.mem.sort` in `wordpress.zig`, `parseTaxonomies`) | Partial coverage | Whether `linkaudit.zig` sorts its HTML file walk is uncertain |
| Absence of timestamps | Not visible in `main.zig` dispatch | Uncertain | Unknown |
| Environment-independent paths | `--root` is user-supplied; path handling within `linkaudit.zig` unknown | Uncertain | Absolute paths in output would break reproducibility across machines |


***

## Filesystem and path safety

| Risk | Mitigation | Mechanically enforced | Tested | Residual gap |
| :-- | :-- | :-- | :-- | :-- |
| Writing into the scanned HTML tree | `main.zig` checks `opts.rootdir != opts.outdir` before dispatch | Yes, in `main.zig` | Not directly tested for link-audit mode (no `parseOptions link-audit` test block exists) | String-equality check only; symlink or normalized-path bypass not addressed at `main.zig` level |
| Path traversal in discovered HTML paths | Unknown — inside `linkaudit.zig` | Unknown | Unknown | Full gap |
| Symlink traversal in `--root` walk | Unknown | Unknown | Unknown | Full gap |
| Overwrite of existing `--out` content | Pattern in other modes is deterministic wipe then write; whether link-audit follows this is uncertain | Unknown | Unknown | Partial output risk on failure is uncertain |
| Accidental recursion into own output | Not applicable if `--root` and `--out` differ (enforced) | Yes (via root equality check) | Indirectly (by the root-inequality enforcement) | Path-prefix containment not checked beyond equality |


***

## Top-level declarations and entry points

The only declaration directly visible from `main.zig` is:


| Declaration | Kind | Purpose | Inputs | Output or effect | Ownership or lifetime |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `linkaudit.run` | Public function | Execute the link-audit against `opts.rootdir`, write reports to `opts.outdir` | `io: std.Io`, `gpa: std.mem.Allocator`, `opts: struct{ rootdir, outdir, quiet }` | Writes `linkaudit.json` and `REPORT.md` under `opts.outdir`; returns `!void` | Allocations owned by `gpa`; arena usage internal to module (uncertain) |

All other declarations (helper functions, report structs, JSON emitters, HTML walker, link extractor) are internal to `linkaudit.zig` and cannot be enumerated from available evidence.

**`main` in `main.zig` for the link-audit path:**

1. `std.process.Init` provides `arena`, `gpa`, `io`, and raw args slice
2. Args are copied into a `std.ArrayList([]const u8)` on the arena
3. `parseOptions` parses the args; `--mode link-audit` (or alias) sets `opts.mode = .linkaudit`
4. `main` checks `opts.rootdir != opts.outdir`; if equal, emits stderr and returns exit code 2
5. `linkaudit.run(io, gpa, .{ .rootdir = opts.rootdir, .outdir = opts.outdir, .quiet = opts.quiet })` is called
6. On error, `std.log.err("migration-lab link-audit failed: {s}", .{@errorName(err)})` is emitted and exit code 3 is returned
7. On success, exit code 0 is returned

***

## Ownership and lifetime model

The `main.zig` entry point owns:

- `init.arena` — arena allocator for argument collection; freed on process exit via `std.process.Init` lifecycle
- `init.gpa` — general-purpose allocator passed to `linkaudit.run`; whether the module uses it directly or wraps an internal arena is unknown

The dispatch in `main.zig` passes `gpa` (not `cold`, the arena allocator) to `linkaudit.run`. Whether `linkaudit.zig` creates its own arena internally (as `themematerialize.zig` does: `var arena = std.heap.ArenaAllocator.init(gpa); defer arena.deinit();`) is uncertain. If it follows that pattern, allocations for path lists, HTML bodies, and report buffers would be freed on arena deinit at the end of `run`. If it allocates directly from `gpa`, callers would depend on the module to free all its allocations before returning.

Claim of leak freedom: **uncertain** — no allocator-checked test for the link-audit mode is confirmed from available evidence.

***

## Error and diagnostic behavior

| Condition | Detection point | User-visible behavior | Exit behavior | Partial output risk |
| :-- | :-- | :-- | :-- | :-- |
| `--root` equals `--out` | `main.zig` before dispatch | `"--out must differ from --root"` to stderr | Exit 2 | None — `linkaudit.run` not called |
| Unknown CLI flag | `parseOptions` in `main.zig` | `"unknown argument, try --help"` to stderr | Exit 2 | None |
| Missing value for flag | `parseOptions` | `"missing value for flag, try --help"` to stderr | Exit 2 | None |
| Any `!void` error from `linkaudit.run` | `main.zig` catch block | `"migration-lab link-audit failed: &lt;ErrorName>"` to stderr | Exit 3 | Possible — partial output may exist in `--out` |
| Structured per-file or per-link errors | Internal to `linkaudit.zig` | Unknown — may be reported in `linkaudit.json` findings rather than stderr | Unknown | Unknown |
| Output directory creation failure | Likely inside `linkaudit.run` | Likely propagated as an error to `main.zig` → exit 3 | Exit 3 | None or partial |

Whether link extraction failures (e.g., malformed HTML, unreadable files) are propagated as fatal errors or recorded as findings in the JSON report is unknown from available evidence.

***

## Relationships to other files

| Related file or subsystem | Relationship | Direction | Authority |
| :-- | :-- | :-- | :-- |
| `tools/migration-lab/main.zig` | Entry point; imports `linkaudit.zig`; owns CLI parsing, allocator, I/O, mode dispatch | Incoming (main.zig → linkaudit.zig) | `main.zig` is authoritative for CLI surface |
| `tools/migration-lab/build.zig` | Compiles both files into `boris-migration-lab` | Build integration | `build.zig` is authoritative for build topology |
| `tools/migration-lab/archaeology.zig` et al. | Sibling mode implementations; same structural pattern | Peer | Each module is independently authoritative for its mode |
| Boris product HTML output (user-specified `--root`) | Input evidence — generated static site HTML | Incoming (HTML tree → tool) | Boris product is authoritative for the content; tool reads it opaquely |
| `linkaudit.json` | Generated output | Outgoing | Tool is authoritative; no downstream consumer tracked in evidence |
| `REPORT.md` | Generated output | Outgoing | Tool is authoritative; human review artifact |
| `tools/source-rag/` | No relationship | — | — |


***

## Security and trust boundaries

The link-audit tool reads arbitrary HTML from a developer-controlled generated output tree. The trust boundary is:

- **`--root` directory contents:** Treated as trusted in the sense that they are generated by `boris` from the developer's own content. However, if `--root` pointed to an untrusted or adversarially-crafted HTML tree, the tool would process arbitrary bytes as HTML. The extraction of `href` values from HTML is done textually (pattern consistent with the migration-lab's general approach of avoiding full-parser dependencies). Maliciously crafted attribute values (e.g., extremely long strings, binary content embedded in attributes) could cause large allocations or unexpected behavior — this is not tested.
- **Path traversal via extracted link targets:** `href` values in HTML could contain `../` sequences. Whether `linkaudit.zig` validates or rejects these before attempting route lookups is unknown. If it performs filesystem operations on resolved paths, a `../`-containing link target could cause reads outside `--root`.
- **Output escaping in `linkaudit.json`:** Filenames and link targets written into JSON must be escaped. The migration-lab convention (visible in `appendJson` in `themematerialize.zig`) performs explicit JSON string escaping. Whether `linkaudit.zig` follows the same pattern is uncertain.
- **Markdown fence safety in `REPORT.md`:** If link targets are embedded in Markdown code blocks or tables, a target containing a backtick or table pipe could break the Markdown structure. This is a cosmetic issue, not a security risk for static report files.
- **Network exfiltration:** Absent by design. The tool does not access the network.
- **Terminal output:** Filenames or link targets printed to stdout/stderr via the `quiet=false` progress path could contain terminal escape sequences if filenames contain them. This is a local developer tool; the risk is low but not eliminated.
- **Resource exhaustion:** A very large HTML tree or a file containing pathologically many link references could cause significant memory allocation. No allocation bounds are documented or tested for link-audit specifically.

***

## Evidence limitations

- `tools/migration-lab/linkaudit.zig` was not directly accessible in the available source bundles. All claims about internal behavior (link extraction algorithm, route resolution, JSON schema fields, ordering, arena use, path safety) are either **uncertain** or inferred from cross-module patterns.
- The `linkaudit.json` schema — field names, `format`, `schemaVersion`, `toolVersion` values — is unknown. The format identifier string is not confirmed.
- No fixture directory for link-audit (`fixtures/mini-link-audit` or equivalent) has been observed in available evidence.
- The `tools/migration-lab/build.zig` and `build.zig.zon` contents were not directly inspected; build topology claims are based on the `main.zig` file-level comments and the observable pattern across the tool family.
- The root `build.zig` convenience step name for link-audit (and for the migration-lab tool generally) was not confirmed from available evidence.
- Whether `linkaudit.run` wipes a previous `--out` before writing is uncertain; this matters for partial-output safety on repeated runs.
- Whether the `--root` directory is opened with read-only flags is uncertain.
- Cross-platform behavior (Windows path separators, filesystem case sensitivity) is undocumented and untested in available evidence.

***

## Final source assessment

`tools/migration-lab/link_audit.zig` is the implementation module for the `link-audit` mode of the `boris-migration-lab` developer tool. Its responsibility is to walk a generated static HTML tree, extract local link and fragment references, check them against the routes and anchors present in the tree, and write a structured JSON report plus a Markdown summary — without modifying any input file.

**Strongest supported guarantees:** The `--root`/`--out` separation is structurally enforced by `main.zig` before dispatch. The tool is compiled as a separate executable from the Boris product binary. It does not access the network or invoke subprocesses (documented; structurally consistent with the module's architecture). Exit-code semantics (0/2/3) are defined and enforced in `main.zig`.

**Weakest and least-tested boundaries:** Internal path safety (traversal in extracted link targets), symlink handling in the HTML walk, output atomicity on failure, and schema stability of `linkaudit.json` are all unconfirmed from available evidence. The module has no confirmed fixture integration test and is the only mode in `main.zig` lacking a `parseOptions` test block.

**Separation from Boris product runtime:** Complete. The module has no import from Boris product source, no shared build target, and no runtime coupling. It operates on `boris` outputs, not `boris` internals.

**Quality of available evidence:** Limited to `main.zig` dispatch behavior and usage text. The `linkaudit.zig` implementation body was not accessible in the source bundles used for this dossier. All internal behavior claims are uncertain or inferred from cross-module patterns.

**Most important unresolved question:** What is the JSON schema for `linkaudit.json`—specifically its `format` identifier, schema version, field inventory, and whether fragment resolution is included or only route-level checks are performed?
