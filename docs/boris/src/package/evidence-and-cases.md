---
title: "`src/package.zig` evidence and cases"
id: docs/boris/src/package/evidence-and-cases
parent: docs/boris/src/package
status: draft
tags: [boris, zig, source-reference, evidence, package]
---

# `src/package.zig` evidence and cases

## Test harness construction

All tests are declared directly inside `src/package.zig` using Zig's inline `test "…" { … }` blocks. They are compiled and run as part of whatever test step includes this file as a root module.

The tests import no external test-double or mock. They call `run(std.testing.io, std.testing.allocator, opts)` directly. `std.testing.io` provides a live I/O handle backed by the process filesystem. `std.testing.allocator` is the standard leak-detecting allocator.

The fixture content trees consumed by the tests are:
- `docs/contracts/fixtures/valid/content` — a small valid multi-page tree (used as the happy-path fixture throughout)
- `docs/contracts/fixtures/missing-parent/content` — a tree with a missing-parent diagnostic that forces `pipeline.run` to return `ok = false`

Test output directories are written under `test-output/package-*` (unique per test case) and cleaned up with `defer cwd.deleteTree(io, packages_dir) catch {}`.

There are no build options that alter `package.zig` test behaviour beyond the `test_fail_before_archive_install` field on `Options`, which is a runtime parameter passed directly in the test body.

The production binary cannot accidentally use any test injection because `test_fail_before_archive_install` defaults to `false` and is only set explicitly in one test.

No `src/apex.zig` involvement; no hostile C implementation; no linked C libraries; no vendor headers.

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `renderVersionJson` | `pub fn` | Produces `MACHINE-READABLE-VERSION.json` bytes | `gpa`, `include_rag: bool` | JSON bytes containing fixed keys in a fixed order | Key presence: `format`, `package_schema_version`, `product_version`, `compiler_id`, `ir_schema_version`, `rag_format`, `rag_schema_version`, `include_rag` |
| `renderVersionJson: fixed keys and product constants` | `test` | Verifies key presence, product constant embedding, `include_rag: true`, and key ordering | `include_rag = true` | All keys present; `i_fmt < i_psv < i_prod < i_comp < i_ir` | Key order is normative and stable |
| `run` | `pub fn` | Full package build: IR (+ optional RAG) → stage → SHA256SUMS → tar → install | `Options` struct with various fields | `Result{ok, failure, archive_path, page_count, include_rag}` | Move-aside install; stage cleaned; archive present iff `ok` |
| `freeResult` | `pub fn` | Releases `gpa`-owned `Result.archive_path` slice | `gpa`, `*Result` | `archive_path` set to `""` | Caller must call after consuming `archive_path` |
| `package: valid fixture IR-only produces archive with expected members` | `test` | Integration: builds a tar from the valid fixture and walks its entries | `include_rag = false`, valid fixture | `saw_version`, `saw_sums`, `saw_manifest`, `saw_graph`, `saw_report` all true; `saw_rag` false; stage absent after success | Archive membership; stage cleanup |
| `package: dual-run same host produces identical tar bytes (IR-only)` | `test` | Determinism: two sequential builds to the same packages dir produce byte-identical archives | Same `content_root`, same `packages_dir`, `include_rag = false` | `expectEqualSlices(u8, a, b)` | No ambient entropy (timestamps, mtime, sort order) |
| `package: content failure leaves no archive` | `test` | Validates that a content-validation failure does not write a final archive and leaves no stage | `missing-parent` fixture, `include_rag = false` | `result.ok == false`, `result.failure == .content`, no archive file, no stage directory | Content failure isolation |
| `package: failed install preserves previous archive` | `test` | Verifies move-aside install safety via `test_fail_before_archive_install` injection | First successful run, then run with injection flag set | `expectError(error.TestInjectedArchiveInstallFailure, failed)`; archive bytes identical to prior; no `.tmp` or `.prev` residue | Prior archive survives a failed install attempt |
| `package: second success replaces via move-aside without leftover prev` | `test` | Verifies clean state after a successful second publish over an existing archive | Two sequential successful runs | Archive present and readable; no `.tmp` or `.prev` files remain | Move-aside does not leave residue on success |
| `parseCli` / `parseArgs` / `main` | `fn` (private/pub) | CLI argument parsing and exit-code mapping | Various flag combinations | Correct `Options` or `ParseError`; `ExitCode` values | Duplicate-flag detection; `--archive` path-separator rejection; help short-circuit |
| `normalizeRelPath` | `fn` (private) | Path normalization: strip leading separators, collapse doubles, unify to `/` | Raw paths with `\` or `//` | Normalized relative path string | Used for tar entry names and stage file enumeration |
| `collectFilePaths` | `fn` (private) | Recursively walks a directory and returns sorted relative paths | `Io.Dir` for the stage root | Lexicographically sorted `[][]const u8` | Deterministic tar entry order |
| `renderSha256Sums` | `fn` (private) | Hashes each payload file and produces a `SHA256SUMS`-formatted string | Stage dir, sorted paths | Lines of `<hex>  <rel>` excluding `SHA256SUMS` itself | Self-exclusion; deterministic ordering |
| `writeTarFromStage` | `fn` (private) | Writes a complete `.tmp` archive, then installs it with move-aside | Stage dir, sorted paths, out dir, archive name, injection flag | Archive at `archive_name`; prior archive preserved on injection failure | Move-aside protocol; temp cleanup |

## Hostile-case walkthrough

The tests in this file exercise operational fault injection, not C ABI hostility. The relevant cases are documented below.

***

### `test_fail_before_archive_install` injection

**Injected behavior:**
`Options.test_fail_before_archive_install = true` causes `writeTarFromStage` to return `error.TestInjectedArchiveInstallFailure` immediately after the `.tmp` file is fully written and closed, before any rename of the temp or the live archive.

**Wrapper boundary exercised:**
The install sequence inside `writeTarFromStage`: specifically, the branch between "temp is fully written" and "rename live archive to `.prev`".

**Expected response:**
`run` propagates `error.TestInjectedArchiveInstallFailure` as a Zig error (not a `Result` with `ok = false`). The caller's `errdefer` is responsible for stage cleanup. The prior archive under `archive_name` must remain byte-identical to what it was before the failed run.

**Forbidden unsafe response:**
Deleting the live archive before the replacement temp is ready; leaving a `.tmp` or `.prev` file after the error; returning a successful `Result` despite the injected failure.

**Evidence strength:**
Directly demonstrated. The test ("package: failed install preserves previous archive") reads the archive bytes before the injection, runs with injection enabled, then reads the archive bytes again and calls `expectEqualSlices`. It also checks for the absence of `.tmp` and `.prev` files.

**Residual gap:**
The injection fires only at one specific point in the rename sequence. The test does not cover the case where the `.prev` rename succeeds but the final rename of `.tmp` to `archive_name` fails for a non-injection reason (e.g., a real filesystem error). That path has a `catch` block that attempts to restore `.prev`; the restoration is structurally present but not tested with a real rename failure.

***

### Content-validation failure with no prior archive

**Injected behavior:**
`pipeline.run` is called against the `missing-parent/content` fixture, which forces `ir_result.ok = false` and `ir_result.failure = .content`.

**Wrapper boundary exercised:**
The early-return path in `run` immediately after `pipeline.run` returns a non-`ok` result, before any stage write.

**Expected response:**
`run` returns a `Result{ok: false, failure: .content, page_count: …}`. No archive is written. The stage directory and the `packages_dir` directory may or may not exist (both are tolerated), but no file named `archive_name` is present.

**Forbidden unsafe response:**
Writing a partial archive; leaving a stage directory; returning `ok = true`.

**Evidence strength:**
Directly demonstrated. The test ("package: content failure leaves no archive") opens `packages_dir` (if it exists) and asserts the archive file cannot be opened.

**Residual gap:**
Only the `FailureKind.content` path is tested. The `FailureKind.io` path (e.g., `pipeline.run` returning a Zig error rather than a `Result`) is not tested with injection; it would propagate as an error from `run` itself. The RAG failure path (when `include_rag = true` and `rag_result.ok()` returns false) is structurally present in `run` but has no dedicated test.

***

### Second successful run over an existing archive (move-aside + cleanup)

**Injected behavior:**
No fault injection; two sequential successful `run` calls to the same `packages_dir`.

**Wrapper boundary exercised:**
The branch in `writeTarFromStage` where `archive_name` already exists: `out_dir.rename(archive_name, out_dir, prev_name, io)` succeeds, setting `had_prev = true`; the subsequent rename of `.tmp` to `archive_name` must also succeed; then `.prev` must be deleted.

**Expected response:**
The archive exists and is readable. No `.tmp` or `.prev` files remain in `packages_dir`.

**Forbidden unsafe response:**
Leaving `.prev` or `.tmp` residue; corrupting or removing the archive.

**Evidence strength:**
Directly demonstrated by "package: second success replaces via move-aside without leftover prev".

**Residual gap:**
The test does not verify that the second archive's contents are correct beyond its existence; it relies on the determinism test for byte identity. The cross-volume rename failure path (where `out_dir.rename` returns `error.CrossDevice`) falls back to a direct install attempt and is not tested.

***

### Determinism across two independent runs

**Injected behavior:**
No fault injection; two `run` calls with the same `content_root` and `packages_dir` but in sequence (second run sees first archive already in place).

**Wrapper boundary exercised:**
`collectFilePaths` (sort order), `renderVersionJson` (fixed key order, no timestamps), `renderSha256Sums` (deterministic hash order), `writeTarFromStage` (fixed `mtime = 0`, fixed `mode = 0o644`, fixed `archive_root`).

**Expected response:**
`expectEqualSlices(u8, a, b)` — the raw tar bytes are identical between the two runs.

**Forbidden unsafe response:**
Any embedded timestamp, host path, random value, or non-deterministic hash-map iteration order.

**Evidence strength:**
Directly demonstrated by "package: dual-run same host produces identical tar bytes (IR-only)". The doc-comment on `writeTarFromStage` notes that the same-directory rename is used (cross-device atomic replace not claimed), and that `mtime=0` and sorted file order are deliberate.

**Residual gap:**
Determinism is tested only for `include_rag = false`. The RAG path adds `rag.run` output; its determinism is covered separately in `rag.zig` tests but not in the combined-package tar test.

***

## Control flow

### `run` — success path (IR-only)

```text
run(io, gpa, opts)
    → cwd.deleteTree(stage_rel)        [clean any prior crash residue]
    → cwd.createDirPath(packages_dir)
    → cwd.createDirPath(stage_rel)
    → cwd.createDirPath(ir_rel)
    → pipeline.run(io, gpa, {content_root, out_dir: ir_rel})
        → scan → parse → graph validate → freeze → publish IR JSON
        → returns Result{ok: true, pages: [...]}
    → [if include_rag] rag.run(io, gpa, {content_root, out_dir: rag_rel})
    → renderVersionJson(gpa, include_rag)
        → write to stage/MACHINE-READABLE-VERSION.json
    → collectFilePaths(io, gpa, stage)   [sorted; excludes SHA256SUMS]
    → renderSha256Sums(io, gpa, stage, payload_paths)
        → write to stage/SHA256SUMS
    → collectFilePaths again             [now includes SHA256SUMS; re-sorted]
    → cwd.openDir(packages_dir)
    → writeTarFromStage(io, gpa, stage, all_paths, packages, archive_name, false)
        → create packages/.{archive}.tmp
        → tar_w.setRoot("boris-package")
        → for each path: readFileAlloc + writeFileBytes (mtime=0, mode=0o644)
        → tar_w.finishPedantically()
        → tar_file.close()
        → [test_fail_before_install? → delete tmp, return error]
        → rename archive_name → .{archive}.prev   [if prior exists]
        → rename .{archive}.tmp → archive_name
        → delete .{archive}.prev                  [if had_prev]
    → cwd.deleteTree(stage_rel)          [success: drop stage]
    → gpa.dupe(archive_rel)
    → return Result{ok: true, archive_path: owned, page_count, include_rag}
```


### `run` — content-validation failure path

```text
run(io, gpa, opts)
    → pipeline.run → Result{ok: false, failure: .content}
    → cwd.deleteTree(stage_rel)
    → return Result{ok: false, failure: .content, page_count, include_rag}
    [no archive written; no stage remains]
```


### Test: `test_fail_before_archive_install` injection

```text
test "package: failed install preserves previous archive"
    → run(valid, packages_dir)           [first run; archive created]
    → readFileAlloc(archive) → prior
    → run(valid, packages_dir, test_fail_before_install=true)
        → pipeline.run → ok
        → writeTarFromStage
            → write .tmp fully
            → test_fail_before_install==true:
                → deleteFile(.tmp)
                → return error.TestInjectedArchiveInstallFailure
    → expectError(error.TestInjectedArchiveInstallFailure, failed)
    → readFileAlloc(archive) → after
    → expectEqualSlices(prior, after)    [archive byte-identical]
    → assert no .tmp or .prev residue
```
