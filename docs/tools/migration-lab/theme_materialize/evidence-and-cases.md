---
title: "`tools/migration-lab/theme_materialize.zig` evidence and cases"
id: docs/tools/migration-lab/theme_materialize/evidence-and-cases
parent: docs/tools/migration-lab/theme_materialize
status: draft
tags: [boris, zig, tools, evidence, migration-lab, theme_materialize]
---

# `tools/migration-lab/theme_materialize.zig` evidence and cases

## Operational walkthroughs

### Default theme materialization

**Invocation:**

```
zig build run -- --mode theme-materialize \
  --root fixtures/mini-theme-astro \
  --ledger tmp/theme-arch-out/adaptationledger.json \
  --out tmp/theme-materialize-out
```

**Inputs:**
The source theme tree at `fixtures/mini-theme-astro` (read-only) and `adaptationledger.json` from a prior `theme-archaeology` run. The ledger contains entries for CSS tokens, fonts, images, a license, and a layout.

**Execution path:**
`main.zig` → validates flags, opens `themematerialize.run` → `refuseOutputInsideSource` → ledger load + JSON parse → CSS pre-scan → main entry loop → `isSafeRelativePath` checks → `hasDroppedCompanionEvidence` checks → `readFile` + `sha256Hex` verify → `writeBytes` copy → layout generation via `emitLayout` → license copy → manifest/report/provenance emit.

**Outputs:**
`theme/assets/css/tokens.css`, `theme/assets/fonts/site.woff2`, `theme/assets/images/logo.svg`, `theme/assets/hero.png`, `theme/LICENSE`, `theme/layouts/main.html`, `materialize-manifest.json`, `MATERIALIZE-REPORT.md`, `PROVENANCE.md`.

**Deterministic properties:**
Output is byte-for-byte identical across repeated runs on the same host, directly demonstrated by the two-run test.

**Failure behavior:**
IO errors (source file missing, output write failure) propagate as Zig errors, caught by `main.zig`, logged as `migration-lab theme-materialize failed: &lt;ErrorName>`, exit code 3. Invalid ledger format returns `error.InvalidLedger`.

**Evidence strength:** Directly demonstrated (inline test).

**Residual gap:** Cross-platform determinism not tested. Stale files from a previous run are not cleaned up.

***

### Hostile fixture — refused unsafe assets

**Invocation:**

```
zig build run -- --mode theme-materialize \
  --root fixtures/hostile-theme-astro \
  --ledger tmp/theme-materialize-hostile-arch/adaptationledger.json \
  --out tmp/theme-materialize-hostile-out
```

**Inputs:**
`fixtures/hostile-theme-astro` containing CSS with remote imports (`@import url(https://...)`), stylesheets with traversal evidence, duplicate assets, and unsupported components.

**Execution path:**
Same as above. `hasDroppedCompanionEvidence` returns `true` for `remote-ref.css` and `evil.css`; both are refused. A safe duplicate image (`dup.png`) is copied normally. The layout is emitted without a `<link>` stylesheet element because no safe CSS passed all gates.

**Outputs:**
`theme/assets/images/dup.png`, `theme/layouts/main.html` (no stylesheet href), `MATERIALIZE-REPORT.md` (contains `"source has dropped remote or unsafe dependency evidence"`).

**Deterministic properties:**
Refusals are deterministic given a deterministic ledger.

**Evidence strength:** Directly demonstrated (hostile fixture test).

**Residual gap:** The test does not check `PROVENANCE.md` content or `materialize-manifest.json` structure in this path.

***

### Invalid CLI invocation — missing ledger

**Invocation:**

```
zig build run -- --mode theme-materialize --root . --out out
```

(no `--ledger`)

**Execution path:**
`main.zig` detects missing `opts.ledgerpath`; logs `"theme-materialize mode requires --ledger FILE"`; prints usage; returns exit code 2. `themematerialize.run` is never called.

**Evidence strength:** Documented contract; structurally enforced in `main.zig`.

***

## Control flow

```text
process entry (main.zig)
    → parse CLI arguments
    → validate --mode theme-materialize flags (ledger required, --out ≠ --root, --out ≠ --ledger)
    → dispatch to themematerialize.run(io, gpa, opts)

themematerialize.run
    → archaeology.refuseOutputInsideSource(rootdir, outdir)
    → validate opts.ledgerpath safety (isSafeRelativePath or absolute)
    → init arena over gpa
    → open source dir (Io.Dir.cwd.openDir rootdir)
    → read ledger file into arena buffer
    → std.json.parseFromSlice → parsed.value
    → validate: .object with .entries .array
    → createDirPath(outdir), createDirPath(theme/assets), createDirPath(theme/layouts)
    → pre-scan entries: find first safe preserve CSS → set csspath
    → main entry loop (for entries.array.items):
        → jsonString(entry, "sourcepath") → isSafeRelativePath check
        → branch on (category, decision):
            preserve + (css|font|image):
                → hasDroppedCompanionEvidence check
                → markerPath(proposed, "theme/assets") → isSafeRelativePath check
                → duplicate destination check
                → readFile(source, sourcepath)
                → sha256Hex verify vs. ledger sha256 (if non-empty)
                → writeBytes(output, destination, bytes)
                → record csspath if first CSS
            preserve + license:
                → readFile, writeBytes("theme/LICENSE")
            adapt + layout (first only):
                → emitLayout(a, csspath) → writeBytes("theme/layouts/main.html")
            (all other rows):
                → status = skipped or refused (various reasons)
        → actions.append(action)
    → emitManifest → writeBytes("materialize-manifest.json")
    → emitReport → writeBytes("MATERIALIZE-REPORT.md")
    → emitProvenance → writeBytes("PROVENANCE.md")
    → optional progress print (unless quiet)
    → return (arena deinit on defer)
```


***

## Tests, fixtures, and evidence coverage

| Test or fixture | Scope | Property demonstrated | Evidence strength | Not demonstrated |
| :-- | :-- | :-- | :-- | :-- |
| `test "theme materialize mini fixture is deterministic and source preserving"` | Full `run` on `fixtures/mini-theme-astro` | Two-run byte identity for all 9 named outputs; layout contains `content` slot marker and `asset-url` placeholder | Directly demonstrated | Cross-platform; allocation failure; stale output cleanup; partial-write recovery |
| `test "theme materialize refuses unsafe ledger paths"` | `isSafeRelativePath` unit test | `../escape.css`, `css/../.css`, `/absolute.css` refused; `public/css/site.css` accepted | Directly demonstrated | Windows absolute paths; Unicode path components; null byte injection |
| `test "theme materialize hostile fixture refuses unsafe stylesheet copies"` | Full `run` on `fixtures/hostile-theme-astro` | `remote-ref.css` and `evil.css` not written; safe `dup.png` written; layout has no stylesheet/https/script strings; report contains refusal reason | Directly demonstrated | Manifest JSON structure in hostile path; PROVENANCE.md in hostile path |
| `fixtures/mini-theme-astro` | Test fixture | Happy-path source with CSS, fonts, images, license, layout | Test input | Not a golden output comparison on its own |
| `fixtures/hostile-theme-astro` | Test fixture | CSS with remote imports, traversal evidence, duplicate assets | Test input | PHP theme files, very large assets |

No golden output files for `themematerialize` are tracked in the repository. Determinism is verified by two-run byte comparison, not by comparison to a committed expected output.

***
