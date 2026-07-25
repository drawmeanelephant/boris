---
title: "`src/target.zig` evidence and cases"
id: docs/boris/src/target/evidence-and-cases
parent: docs/boris/src/target
status: draft
tags: [boris, zig, source-reference, evidence, target]
---

# `src/target.zig` evidence and cases

## Inline tests

### `isValidTargetName validation rules`

Directly exercises `isValidTargetName`. Checks that `"prod"`, `"staging-2"`, and `"dev_test.site"` are accepted; and that `""`, `"."`, `".."`, `"prod/staging"`, `"prod\\staging"`, and `"prod?"` are rejected.

**Evidence:** directly demonstrated by assertions.

### `sortTargetSpecsByName is deterministic`

Constructs three `TargetSpec` values in non-alphabetical order, calls `sortTargetSpecsByName`, and asserts the resulting order is `alpha`, `prod`, `staging`. Also asserts that the optional `layout_path` field moves with its spec (i.e. the sort is stable-by-association, not a name-only sort that could discard associated data).

**Evidence:** directly demonstrated.

### `hasAbsPathPrefix boundary`

Exercises the `/`-boundary guard: confirms `/tmp/ws-evil/dist` does not match prefix `/tmp/ws`, and that `/tmp/ws/dist-prod` does not match `/tmp/ws/dist`. Confirms exact match and proper child match are accepted.

**Evidence:** directly demonstrated.

### `validateTargets overlap, nesting, sort, and escape checks`

The largest test, consisting of multiple independent sub-cases within a single `test` block. Each sub-case uses a fresh `[_]TargetSpec` literal and asserts a specific outcome:


| Sub-case | Input | Expected |
| :-- | :-- | :-- |
| Normal sort | `["staging"→dist/stage, "prod"→dist/prod]` | 2 plans, sorted `[prod, staging]` |
| Sibling dirs (no collision) | `["a"→dist, "b"→dist-prod]` | 2 plans (sibling prefix is not a child) |
| Duplicate target name | two `"prod"` | `error.DuplicateTargetName` |
| Invalid target name | `"prod/site"` | `error.InvalidTargetName` |
| Equal output dirs | both `dist/prod` | `error.TargetOutputCollision` |
| Parent/child nesting | `dist/prod` + `dist/prod/stage` | `error.TargetOutputCollision` |
| Workspace escape | `../outside` | `error.WorkspaceEscape` |
| Workspace root | `.` | `error.TargetOutputCollision` |
| Output == content root | `content` with default opts | `error.TargetOutputCollision` |
| Output nested under content | `content/out` | `error.TargetOutputCollision` |
| Output == layout dir | `layouts` | `error.TargetOutputCollision` |
| Custom content_root | output `content` with `content_root="docs/src"` | 1 plan (no collision) |
| Input-order independence | same two specs in two orderings | same plan names and layout paths in both outputs |

**Evidence:** directly demonstrated for all listed sub-cases.

## Control flow

```text
CLI parser
  → []TargetSpec (argv views + GPA rule slices)
  → validateTargets(io, gpa, specs, options)
      1. len == 0? → error.NoTargetsSpecified
      2. foreach spec:
           isValidTargetName? → error.InvalidTargetName
           duplicate name? → error.DuplicateTargetName
      3. std.process.currentPathAlloc → cwd_path (normalized)
      4. foreach spec:
           output_dir empty? → error.EmptyTargetDirectory
           resolveNormalized(gpa, cwd_path, output_dir) → normalized
           hasAbsPathPrefix(normalized, cwd_path)? → error.WorkspaceEscape
           normalized == cwd_path? → error.TargetOutputCollision
           effectiveLayout → layout (empty? → error.EmptyTargetDirectory)
           validateLayoutPath(layout) → error.InvalidLayoutPath
           foreach rule: validateLayoutPath → error.InvalidLayoutPath
           rejectMixedThemeRoots → error.MixedThemeRoots
           plans.append(TargetPlan{...normalized...})
      5. resolveNormalized(content_root) → content_abs
         foreach plan:
           collectDeclaredLayouts → declared layout paths
           foreach path: resolveNormalized → protected_layouts entries
           rejectSymlinkAlongPath(layout_path)
      6. foreach plan i:
           pathsNestOrEqual(path_a, content_abs)? → error.TargetOutputCollision
           foreach protected_layout: pathsNestOrEqual? → error.TargetOutputCollision
           rejectSymlinkAlongPath(output_dir) → error.TargetOutputSymlink
           foreach plan j (j≠i): pathsNestOrEqual? → error.TargetOutputCollision
      7. std.mem.sort(TargetPlan, plans.items, name_less)
      → plans.toOwnedSlice(gpa)
  → []const TargetPlan (caller owns; each .resolved_output_dir is GPA-owned)
  → per-target render pass (assemble, theme copy, page write)
```
