---
title: "`src/cli.zig` evidence and cases"
id: docs/boris/src/cli/evidence-and-cases
parent: docs/boris/src/cli
status: draft
tags: [boris, zig, source-reference, evidence, cli]
---

# `src/cli.zig` evidence and cases

## `parseOptions` control flow

The function processes argv in four logical phases:

### Phase 1 — Command dispatch (before the flag loop)

```text
args[1] == "check"  → command = .check; i += 1
args[1] == "impact" → command = .impact; i += 1
(else)              → command = .build
```

`impact` requires exactly one non-flag positional argument (the target id). The id may immediately follow the subcommand or come after flags (`boris impact --quiet ID`); it is captured in the flag loop when `impact_id` is still unset. A second positional is `error.UnexpectedPositional`. After the loop, if no id was captured (`boris impact` or `boris impact --quiet`), `error.MissingValue` is returned — the immediate-return form was removed so flags may precede the positional.

### Phase 2 — Flag loop (linear scan)

The loop processes `args[i]` for `i` from the post-command position to the end:

- `--help` / `-h`: immediately returns a partial `Options{.help = true}` without further validation.
- Boolean flags (`--quiet`, `--rag`, `--html`, `--incremental`, `--watch`, `--textile`, `--no-rag`, `--context`, `--llms`): set a `saw_*` boolean; return `error.DuplicateFlag` if already set.
- Value flags (`--input`, `--out`, `--rag-dir`, `--html-dir`, `--html-layout`, `--rag-dir`, `--context-dir`, `--llms-path`, `--jobs`, `-j`): call `takeValue` to extract inline (`--flag=value`) or next-token (`--flag value`) form; apply per-flag validation (e.g., `--jobs` range 1–64, `--llms-path` rejects absolute paths, `--html-layout` calls `layout_select.validateLayoutPath`).
- `--target NAME=DIR`: splits on `=`, validates name via `target_mod.isValidTargetName`, checks for duplicate name, appends to `targets`.
- `--target-layout NAME=PATH`: validates name, validates path via `layout_select.validateLayoutPath`, appends to `target_layouts` (a local pending list).
- `--layout-rule TARGET SELECTOR PATH`: consumes three following argv tokens (not a value flag), validates name, rejects flag-like tokens, validates selector via `layout_select.parseSelector`, validates path, appends to `pending_rules`.
- `--theme ROOT`: validates root via `layout_select.validateLayoutPath`, sets `theme_root`.
- `--format human|json`, `--report PATH`: analysis output format and report path.
- Anything starting with `-` that was not matched: `error.UnknownFlag`.
- Anything not starting with `-`: `error.UnexpectedPositional`.


### Phase 3 — Post-scan resolution

After the loop, in fixed order:

1. **Theme sugar:** If `theme_root` is set, allocate `"{root}/layouts/main.html"`, validate it, set `owned_html_layout = true`. Conflict with `--html-layout` produces `error.ConflictingFlags`.
2. **Derived booleans:** Compute `explicit_html`, `wants_rag`, `wants_context`, `wants_llms`, `wants_ir` from the `saw_*` set.
3. **Command vs build conflicts:** Non-build commands reject any output-selection, HTML, RAG, jobs, watch, incremental, theme, or layout flags.
4. **Build vs analysis conflicts:** Build mode rejects `--format` and `--report`.
5. **Conflict matrix:** 15+ explicit pairwise conflict checks (see "Conflict matrix" section below).
6. **Mode selection:** Priority: explicit HTML → rag → context → llms → ir → html (default).
7. **Synthetic default target:** In HTML mode without explicit `--target` flags, append a synthetic `TargetSpec{.name = "default", .output_dir = ...}`.
8. **Target-layout binding:** For each entry in `target_layouts`, find the matching target by name and assign `layout_path`. Unknown names → `error.InvalidValue`. Duplicate assignments → `error.DuplicateFlag`.
9. **Layout-rule attachment:** For each target, count matching rules (reject over `layout_select.max_rules_per_target = 256`), allocate a `[]LayoutRule` slice, parse each selector, call `layout_select.rejectDuplicateSelectors`, call `layout_select.sortRulesCanonical`. Unknown rule targets (no matching `--target` or synthetic `default`) → `error.InvalidValue`.
10. **Target sort:** If `targets.items.len > 1`, call `target_mod.sortTargetSpecsByName` for canonical argv-order-independence.
11. **Return:** Construct and return the mode-specific `Options` value. `html_dir` is set to `null` when explicit targets are present (multi-target HTML does not use a single `html_dir`). `incremental` is set to `saw_incremental or saw_watch` (watch implies incremental).

### Phase 4 — `takeValue` helper

```zig
fn takeValue(args, i, arg, comptime name) ParseError![]const u8
```

Handles both `--flag=value` (inline, returns `arg[eq_prefix.len..]`) and `--flag value` (next-token, increments `i.*`). Returns `error.EmptyValue` if the extracted string is empty. Returns `error.MissingValue` if the next-token form is used but no next token exists.

## Test suite

### Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `"parse: default is HTML mode"` | test | Default no-flag invocation | `boris` | `mode = .html`, `html_dir = "dist"`, target `"default"`, `input_format = .markdown` | Bare CLI defaults |
| `"parse: Textile input mode is explicit and whole-tree"` | test | `--textile` flag across modes | HTML+textile, IR+textile, double-textile | `input_format = .textile`; duplicate → `DuplicateFlag` | `--textile` is a whole-tree format switch |
| `"parse: documentation intelligence commands"` | test | `check` and `impact` subcommands | `check --format json --report`, `impact <id> --quiet`, missing impact ID, check+out conflict, format without command | Correct command/format/report; `MissingValue`; `ConflictingFlags` | Subcommand dispatch and cross-command conflict rules |
| `"parse: --out selects IR mode"` | test | `--out` flag implies IR mode | `boris --out .boris` | `mode = .ir`, `out_dir = ".boris"`, `html_dir = null`, `rag_dir = null` | IR mode selection |
| `"parse: valid modes table"` | test | 19-case mode coverage | All major flag combinations for IR, RAG, HTML | Correct `mode`, `input_dir`, `out_dir`, `rag_dir`, `html_dir`, `quiet`, `jobs` per case | Full mode matrix |
| `"parse: conflicts and missing values table"` | test | 55+ error cases | All known conflict pairs, empty/missing/duplicate/unknown/positional | Exact `ParseError` variant per case | Conflict matrix completeness |
| `"parse: --watch with HTML implies incremental"` | test | `--watch` semantics | `--html --watch`, `--html-dir site --watch --jobs 2`, `--watch --incremental`, bare `--watch` | `watch = true`, `incremental = true` in all cases | Watch/incremental implication |
| `"parse: help short-circuits and does not validate trailing junk"` | test | `--help` early exit | `--help --not-a-real-flag --rag --no-rag`, `-h` | `help = true`; no error despite invalid trailing flags | Help short-circuit |
| `"execute: help does not invoke pipeline"` | test | `execute` dependency injection | Spy with `printHelp` and `run` counts; `--help` opts | `help_calls = 1`, `pipeline_calls = 0`, exit code 0 | `execute` help routing |
| `"execute: build mode invokes pipeline once"` | test | `execute` build routing | Spy; RAG mode opts | `pipeline_calls = 1`, `last_mode = .rag`, exit code 0 | `execute` build routing |
| `"runArgs: usage errors exit 2; help exits 0"` | test | `runArgs` end-to-end | Spy with `reportUsage`; multiple conflict/unknown inputs; valid inputs | Exit 2 for all parse errors; exit 0 for valid; `pipeline_calls` count | `runArgs` error dispatch |
| `"parse: --target flag parsing and conflict checks"` | test | Multi-target parsing and conflicts | Various `--target`, `--html-dir`, `--out`, `--rag`, invalid name/format, duplicate, `--target-layout` binding | Correct target list; correct conflicts; layout assignment | Target and target-layout contract |
| `"findBadArg reports --target"` | test | `findBadArg` best-effort | Various argv with missing/invalid flag tokens | Correct string returned for each case | `findBadArg` output |
| `"parse: --theme sugar selects theme layouts/main.html"` | test | Theme sugar composition | `--theme experimental-theme`, conflict with `--html-layout` | Correct composed path; `owned_html_layout = true`; `ConflictingFlags` | Theme path allocation and conflict |
| `"parse: equivalent --target order yields equivalent configuration"` | test | Target sort canonicalization | Two argv orderings of `prod` and `stage` targets | Identical `targets.items` slice content in both | `sortTargetSpecsByName` canonicalization |
| `"parse: --target-layout order relative to --target is independent"` | test | Target-layout argv-order independence | `--target-layout` before and after `--target` | Identical `layout_path` binding in both orderings | Target-layout binding order-independence |
| `"parse: bare HTML and --html map to default target; --target-layout attaches"` | test | Synthetic default target | Bare, `--html --html-dir`, `--target-layout default=...` | `targets[0].name = "default"`; layout attached correctly | Default target synthesis |
| `"parse: --target with --watch and --incremental"` | test | Multi-target + watch/incremental | Two targets + `--watch --incremental --jobs 2` | Correct target list, `watch/incremental = true`, `html_dir = null` | Multi-target HTML options |
| `"runArgs: invalid target parse errors exit 2"` | test | `runArgs` target error dispatch | Various invalid target invocations via spy | Exit 2 for all; `pipeline_calls = 0`; valid invocation exits 0 | `runArgs` target error coverage |
| `"parse: --layout-rule attaches to default and named targets"` | test | Layout-rule parsing and sort | `--theme` + two `--layout-rule default` entries | Two rules; canonical sort `id` before `role` | Layout-rule attachment and sort |
| `"parse: --layout-rule order independent; unknown target and bad selector fail"` | test | Layout-rule binding order-independence and errors | Two orderings of rules+target; unknown target; bad selectors; duplicate selector; layout-rule + --out/--rag conflicts; missing value | Identical rules in both orderings; expected errors | Layout-rule contract |
| `"parse: layout paths reject .. absolute and backslash escapes"` | test | Path security validation | `..`-containing, absolute, backslash, and valid relative paths for all layout path flags | `InvalidValue` for unsafe; success for relative | `validateLayoutPath` integration |
| `"parse: llms mode and path"` | test | `--llms` and `--llms-path` | `--llms-path public/llms.txt --input docs`; conflicts with `--rag`, `--html`; absolute path | Correct mode/path; `ConflictingFlags`; `InvalidValue` | `llms` mode selection and constraints |

## Hostile-case walkthrough

The tests in this file are correctness and contract tests, not hostile ABI tests. There is no C boundary, no hostile double, and no adversarial allocator. The following subsections document the meaningful boundary cases the tests exercise.

***

### `--help` short-circuits before remaining arg validation

**Injected behavior:**
`--help` appears before a set of flags that would otherwise be invalid (`--not-a-real-flag --rag --no-rag`).

**Wrapper boundary exercised:**
The early-return branch inside the flag loop when `a == "--help"`. The returned `Options` value carries zeroed-out optional fields and an empty `targets` with `capacity = 0` (no allocation for targets occurs).

**Expected response:**
`Options{.help = true}` is returned; `ParseError` is never triggered despite the invalid trailing flags.

**Forbidden unsafe response:**
Allocating the `targets` ArrayList in the help-return path and then not freeing it. The implementation avoids this by returning a literal with `targets = .{ .items = &.{}, .capacity = 0 }`, which requires no deallocation.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test that `Options.deinit` on a help-result (with `owned_html_layout = false` and empty targets) is safe. By code inspection it is safe, but this is not asserted.

***

### Duplicate flag detection

**Injected behavior:**
Every boolean flag and value-taking flag is supplied twice in the same argv (e.g., `--quiet --quiet`, `--rag --rag`, `--input a --input b`).

**Wrapper boundary exercised:**
The `saw_*` guard pattern: each recognizable flag checks its corresponding `saw_*` boolean and returns `error.DuplicateFlag` on the second occurrence.

**Expected response:**
`error.DuplicateFlag` for all duplicate cases in the conflict table.

**Forbidden unsafe response:**
Overwriting a previously parsed value without diagnosis — this would silently allow the last occurrence to win, which could be exploited to bypass conflict detection (e.g., first set a mode, then override it).

**Evidence strength:**
Directly demonstrated for all major flags.

**Residual gap:**
`--layout-rule` does not use a `saw_layout_rule` boolean; instead duplicates are detected post-scan via `layout_select.rejectDuplicateSelectors` per target. This means a duplicate `--layout-rule` with a different target name is not detected as a duplicate at the loop level — it is rejected only if the same (target, selector) pair repeats within a target. This is documented behavior but differs from the `saw_*` pattern used elsewhere.

***

### Missing and empty values for value-taking flags

**Injected behavior:**

- `--input` (and variants) with no following token: `error.MissingValue`.
- `--input ""` (empty string token) and `--input=` (inline empty): `error.EmptyValue`.

**Wrapper boundary exercised:**
`takeValue`: the missing-value branch (`i.* >= args.len`) and the empty-value check (`v.len == 0`).

**Expected response:**
`error.MissingValue` when the token is absent; `error.EmptyValue` when the token is present but empty.

**Forbidden unsafe response:**
Returning an empty-string slice as a valid path, which could cause downstream I/O to interpret it as the current directory or another unintended location.

**Evidence strength:**
Directly demonstrated for `--input`, `--out`, `--rag-dir`, `--html-dir`, `--jobs`, `-j`, and `--jobs=`.

**Residual gap:**
Does not test empty values for `--html-layout`, `--theme`, `--target`, `--target-layout`, `--context-dir`, `--llms-path`, or `--report`. Those paths may also produce `EmptyValue` from `takeValue`, but this is not directly demonstrated.

***

### `--jobs` range and parse validation

**Injected behavior:**
`--jobs 0` (below minimum), `--jobs 65` (above maximum), `--jobs abc` (non-numeric), `--jobs ""` / `--jobs=` (empty), `--jobs` without a value (missing).

**Wrapper boundary exercised:**
`std.fmt.parseInt(usize, val_str, 10)` catch → `InvalidValue`; explicit `if (parsed_val < 1 or parsed_val > 64)` guard.

**Expected response:**
`error.InvalidValue` for 0, 65, and "abc"; `error.EmptyValue` for empty; `error.MissingValue` for absent.

**Forbidden unsafe response:**
Passing an out-of-range job count to the pipeline, which could cause undefined thread-pool behavior or division-by-zero.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Maximum value of 64 is checked by the parser. Whether the pipeline enforces a further constraint (e.g., capping to available CPU count) is outside this file's scope.

***

### Layout path security validation (`..`, absolute, backslash)

**Injected behavior:**
Paths containing `..` components, absolute paths (starting with `/`), paths containing `..` mid-segment (`theme/layouts/../layouts/main.html`), and paths containing backslash (`layouts\main.html`) are passed to `--html-layout`, `--target-layout`, `--layout-rule`, and `--theme`.

**Wrapper boundary exercised:**
`layout_select.validateLayoutPath(path) catch return error.InvalidValue` — called immediately on extraction of the path value. The validation is delegated to `layout_select`; `cli.zig` maps any validation error to `error.InvalidValue`.

**Expected response:**
`error.InvalidValue` for all unsafe forms. A valid relative path (`themes/docs/layouts/home.html`) parses successfully.

**Forbidden unsafe response:**
Passing a `..`-containing or absolute path through to the pipeline, which could cause Boris to read or overwrite files outside the project workspace.

**Evidence strength:**
Directly demonstrated for all four flag types and all three unsafe forms.

**Residual gap:**
The actual rejection logic lives in `layout_select.validateLayoutPath`, not in `cli.zig`. Whether that function covers all OS-specific escape forms (e.g., null bytes, Windows drive letters, UNC paths) is outside this file's scope and not verified here.

***

### Conflict matrix completeness

**Injected behavior:**
All conflict pairs tested in `"parse: conflicts and missing values table"` — over 50 cases including bidirectional ordering variants (e.g., `--rag --no-rag` and `--no-rag --rag`).

**Wrapper boundary exercised:**
The post-scan conflict matrix block in `parseOptions`.

**Expected response:**
`error.ConflictingFlags` for all conflict cases.

**Forbidden unsafe response:**
Allowing a contradictory combination through to the pipeline (e.g., `--rag` + `--out`, which would cause the pipeline to attempt both RAG export and IR output simultaneously).

**Evidence strength:**
Directly demonstrated for all listed conflict pairs.

**Residual gap:**
Conflict detection is post-scan. A hypothetical new flag pair could be added without a corresponding conflict check and would not be caught until a test was added. The test table is the authoritative specification; there is no mechanical enforcement that the conflict matrix is complete relative to all declared flags.

***

### `--theme` heap-allocated path ownership

**Injected behavior:**
`--theme experimental-theme` causes `parseOptions` to allocate `"experimental-theme/layouts/main.html"` via `std.fmt.allocPrint`.

**Wrapper boundary exercised:**
The `owned_html_layout` tracking flag and the `Options.deinit` path that calls `gpa.free(self.html_layout)` when `owned_html_layout = true`.

**Expected response:**
`o.html_layout == "experimental-theme/layouts/main.html"`, `o.owned_html_layout == true`. After `o.deinit(gpa)`, the memory is freed with no leak or double-free.

**Forbidden unsafe response:**
Failing to set `owned_html_layout = true` (leak), or setting it true when the string is a view into argv (double-free/invalid-free), or allocating the string but then returning an error without freeing it.

The `errdefer if (owned_html_layout) gpa.free(html_layout)` guard in the post-scan phase handles the error return path after successful allocation.

**Evidence strength:**
Directly demonstrated for the success path. The error path (allocation succeeds but validation fails) is tested by the invalid theme path cases (`"../evil-theme"`, `"/abs/theme"`), which demonstrate that `InvalidValue` is returned without leaking — this is structurally checked by the test-allocator leak detection, not by an explicit assertion.

**Residual gap:**
The `runArgs` allocator extraction heuristic (`@hasField(@TypeOf(runner.*), "gpa")`) defaults to `std.testing.allocator` in test runners. This is safe for tests. In production, if the binary entry point does not provide a runner with a `gpa` field, the wrong allocator may be used for `opts.deinit`. This gap is not addressed in the file.

***

### Target argv-order canonicalization

**Injected behavior:**
Two equivalent argv sequences that specify the same `--target` names in different orders (`prod` then `stage` vs `stage` then `prod`).

**Wrapper boundary exercised:**
`target_mod.sortTargetSpecsByName(targets.items)` called after mode selection and target-layout binding.

**Expected response:**
Both `Options` values have `targets.items[0].name == "prod"` and `targets.items[1].name == "stage"` — the lexicographically earlier name is always first regardless of argv order.

**Forbidden unsafe response:**
Producing different `Options.targets` orderings for equivalent argv, which would cause the pipeline to process targets in a different sequence and produce non-deterministic build reports.

**Evidence strength:**
Directly demonstrated.

**Residual gap:**
Does not test canonicalization with more than two targets, or with targets whose names differ only in case (which may or may not produce stable ordering depending on the sort comparator in `target.zig`).

## Control flow

### `parseOptions` top-level

```text
parseOptions(gpa, args)
    → Phase 1: detect command subtoken (check | impact | build)
    → Phase 2: flag scan loop
        → takeValue for value-taking flags
        → target_mod.isValidTargetName / layout_select.validateLayoutPath / parseSelector
        → append to targets / target_layouts / pending_rules lists
        → saw_* guard → error.DuplicateFlag
        → unrecognized '-' prefix → error.UnknownFlag
        → no '-' prefix → error.UnexpectedPositional
    → Phase 3: post-scan
        → theme_root? → allocPrint → owned_html_layout = true
        → conflict matrix checks → error.ConflictingFlags
        → mode selection (priority chain)
        → synthetic "default" target if HTML and no explicit targets
        → target_layouts binding loop → error.InvalidValue / DuplicateFlag
        → pending_rules attachment loop → alloc rules slice
            → rejectDuplicateSelectors → sortRulesCanonical
        → sortTargetSpecsByName if len > 1
    → construct and return mode-specific Options struct
```


### `runArgs` dispatch

```text
runArgs(args, runner)
    → gpa = runner.gpa or std.testing.allocator
    → parseOptions(gpa, args)
        → error → runner.reportUsage or printParseError+printUsage → return 2
        → ok opts → defer opts.deinit(gpa)
    → execute(opts, runner)
        → opts.help? → runner.printHelp() → return 0
        → else → runner.run(opts) → return exit_code
```
