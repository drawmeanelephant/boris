---
title: "`src/target.zig` surface and execution"
id: docs/boris/src/target/surface-and-execution
parent: docs/boris/src/target
status: draft
tags: [boris, zig, source-reference, surface, target]
---

# `src/target.zig` surface and execution

## Data types

### `TargetSpec`

The raw, CLI-owned view of one target. Fields are slices into argv or GPA-owned strings from the CLI parser; the struct does not own its memory:

- `name: []const u8` — target name, validated by `isValidTargetName`.
- `output_dir: []const u8` — raw (possibly relative) output directory path as given by the user.
- `layout_path: ?[]const u8` — per-target layout override; `null` means "use global default."
- `layout_rules: []const layout_select.LayoutRule` — GPA-owned slice of layout selection rules; empty when none are declared.

### `TargetPlan`

The resolved, validated output of `validateTargets`. The `resolved_output_dir` field is GPA-owned by the caller (caller must free it). All other fields are views:

- `name`, `output_dir` — views into the originating `TargetSpec`.
- `resolved_output_dir: []const u8` — absolute, `/`-normalized, trailing-slash-stripped path. Owned by caller.
- `layout_path: []const u8` — effective layout path (per-target override or global default). Not owned.
- `layout_rules` — view into the originating `TargetSpec` rule table.

Ownership is asymmetric by design: `validateTargets` allocates only `resolved_output_dir`; all other fields remain views. Callers must free each `plan.resolved_output_dir` and then free the slice itself.

## Key functions

### `validateTargets`

```text
pub fn validateTargets(
    io: Io,
    gpa: Allocator,
    targets: []const TargetSpec,
    options: ValidateTargetsOptions,
) ![]const TargetPlan
```

The central validation gate. Performs the following checks in order:

1. **Empty input guard** — returns `error.NoTargetsSpecified` when the slice is empty.
2. **Name grammar and uniqueness** — calls `isValidTargetName` on each name; O(n²) duplicate-name check across the slice.
3. **CWD resolution** — calls `std.process.currentPathAlloc`, normalizes separators, strips trailing slash.
4. **Per-target path resolution** — for each spec: rejects empty `output_dir`, resolves to an absolute path via `resolveNormalized`, checks workspace membership via `hasAbsPathPrefix`, rejects workspace-root collision (resolved == cwd), validates the effective layout path and all rule layout paths via `layout_select.validateLayoutPath`, enforces a single theme root via `rejectMixedThemeRoots`, and appends a `TargetPlan` to a growing `ArrayList`.
5. **Protected-root collection** — resolves the content root and all declared layout file paths and their parent directories to absolute paths.
6. **Overlap and symlink sweep** — for each plan: checks it does not nest with the content root or any protected layout path or directory; calls `rejectSymlinkAlongPath` on the raw `output_dir`; checks it does not nest or equal any other plan's resolved output path.
7. **Deterministic sort** — sorts `plans.items` in place by name (lexicographic byte order) before returning the owned slice.

The function uses `errdefer` to free all `resolved_output_dir` allocations and deinit the ArrayList on any error path, which is the only GPA-owned memory created during the call.

### `hasAbsPathPrefix`

```text
pub fn hasAbsPathPrefix(path: []const u8, prefix: []const u8, case_insensitive: bool) bool
```

Returns true when `path` equals `prefix` or starts with `prefix + '/'`. The `/` boundary check prevents sibling-prefix false positives (e.g. `/tmp/ws-evil` does not match prefix `/tmp/ws`). Optionally case-insensitive for Windows/macOS. Directly tested.

### `pathsNestOrEqual`

Returns true when either path is a prefix of the other (via `hasAbsPathPrefix` in both directions). Used for the overlap check in step 6 above.

### `rejectSymlinkAlongPath`

Walks progressive path components of a workspace-relative path and calls `cwd.statFile` with `follow_symlinks = false` on each prefix. Returns `error.TargetOutputSymlink` if any component is a symlink. Skips drive-absolute (`C:/`) and POSIX-absolute (`/`) inputs. Errors from `statFile` on missing paths are silently ignored (path need not exist yet). The function is called at validate time and is intended to be called again immediately before opening the output directory to narrow the TOCTOU window, though the in-file tests do not exercise the symlink path directly.

### `rejectMixedThemeRoots`

Calls `theme_mod.themeRootFromLayoutPath` on the fallback layout and on every rule layout path. Returns `error.MixedThemeRoots` if any two layouts resolve to different theme roots (or one is managed and another is legacy). This prevents a target from inadvertently mixing assets from two different managed themes, or from mixing a managed theme with a legacy `layouts/` path.

### `isValidTargetName`

Pure predicate. A valid name is non-empty, not `"."` or `".."`, and composed entirely of `[a-zA-Z0-9\-_.]`. The closed grammar prevents names that would produce ambiguous filesystem paths or shell-expansion hazards.

### `effectiveLayout`

Returns `target.layout_path orelse default_layout`. Single expression, no allocation.

### `sortTargetSpecsByName` / `targetNameLess`

Sort a `[]TargetSpec` in place by `name` in ascending byte order. Used for canonical CLI output ordering; `validateTargets` independently sorts `TargetPlan` values by the same key.

### `printTargetConfigLines`

Diagnostic helper. Prints one line per target to `std.debug.print` (stderr). Format: `  target <name>: out=<output_dir> layout=<effective_layout> rules=N`. Not tested inline.

### `declaredLayoutPaths`

Wraps `layout_select.collectDeclaredLayouts`. Returns a GPA-owned `[]const []const u8` of unique layout paths for a spec. Caller must free the slice (path strings are views into the spec). Not tested inline.

### `resolveNormalized` (private)

Calls `std.fs.path.resolve`, normalizes backslashes to `/`, strips a trailing `/`. Returns a GPA-owned `[]u8`. When the stripped result is shorter than the resolved buffer, allocates a fresh copy and frees the original.

### `normalizeSlashesInPlace`, `stripTrailingSlash`, `caseInsensitiveFs` (private)

Internal helpers. `caseInsensitiveFs` is a compile-time check on `builtin.os.tag` (`windows` or `macos`). `normalizeSlashesInPlace` converts `\\` to `/` in a mutable slice. `stripTrailingSlash` returns a subslice without the trailing `/` when `len > 1`.

## Ownership and allocation contract

`validateTargets` allocates exactly one field per output plan: `resolved_output_dir`. All other `TargetPlan` fields are views into the input `TargetSpec` slice (which must outlive the plan slice). The returned slice itself is GPA-owned. The canonical teardown pattern, as demonstrated by every test sub-case:

```zig
defer {
    for (plans) |plan| gpa.free(plan.resolved_output_dir);
    gpa.free(plans);
}
```

Intermediate allocations created during validation (`cwd_owned`, `content_abs`, `protected_layouts` entries, transient `normalized` buffers on error paths) are all freed before the function returns, via `defer` and `errdefer`. The `protected_layouts` ArrayList frees its own `[]u8` entries in its `defer` block. On any error path, the `errdefer` at the top of the plans-building block frees any `resolved_output_dir` strings already appended and deinits the `ArrayList`.

## Security and safety properties

The following properties are **structurally checked** by code (not merely documented):

- **Workspace membership:** Every resolved output path must have `cwd_path` as an absolute prefix with a `/` boundary — enforced by `hasAbsPathPrefix` on the result of `std.fs.path.resolve`.
- **Workspace-root collision:** A resolved path equal to `cwd_path` in length is rejected — enforced by the `normalized.len == cwd_path.len` check.
- **Sibling-prefix safety:** The `/` boundary in `hasAbsPathPrefix` prevents a path like `/ws-evil` from being accepted under workspace `/ws` — structurally checked and directly demonstrated by the `hasAbsPathPrefix boundary` test.
- **Content and layout protection:** The protected-roots pass collects all declared layout paths and their parent directories and checks them via `pathsNestOrEqual` — structurally checked.
- **Target name grammar:** `isValidTargetName` is a closed whitelist; the character switch has no default accept case.
- **Symlink rejection:** `rejectSymlinkAlongPath` calls `statFile` with `follow_symlinks: false` at validate time. The TOCTOU gap between validation and actual `openDir` is explicitly acknowledged in the source comment; callers are instructed to call the function again immediately before opening the directory.

The following property is **assumed of the OS/stdlib** and not mechanically checked:

- That `std.process.currentPathAlloc` returns the actual current working directory and not an attacker-controlled value.

The following property is **not enforced** by this file:

- That downstream code actually uses the validated `TargetPlan` rather than re-resolving paths independently. Enforcement is by convention and code review, not by type system.
