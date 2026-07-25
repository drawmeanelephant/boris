---
title: "`src/include.zig` evidence and cases"
id: docs/boris/src/include/evidence-and-cases
parent: docs/boris/src/include
status: draft
tags: [boris, zig, source-reference, evidence, include]
---

# `src/include.zig` evidence and cases

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `validateIncludePath accepts relative fragments` | unit test | Path grammar enforcement | Literal accept/reject path strings | `true`/`false` per documented rules | Path grammar: no abs, no `..`, no dotfile, no empty segment, no backslash |
| `scanIncludeDirectives finds one and skips backtick fences` | unit test | Fence-aware scan | Body with backtick fence enclosing one directive and a mid-line directive | 2 hits: `includes/a.md`, `includes/b.md` | Fence suppression; mid-line directive scanning |
| `scanIncludeDirectives skips tilde fences` | unit test | Tilde fence variant | Body with `~~~` fence | 2 hits; `includes/skipped.md` not in results | Tilde fence parity with backtick |
| `scanIncludeDirectives rejects empty path with FailInfo` | unit test | `InvalidPath` propagation | `"&#123;&#123;include   &#125;&#125;"` (whitespace-only path) | `error.InvalidPath`; `fail.line == 1`, `fail.column == 1`, `fail.locus() == "page.md"` | FailInfo locus set to caller's page path |
| `makeDiagnostic is retain-owned and maps codes` | unit test | Diagnostic construction and formatting | `error.IncludeMissing`, `fail` at line 3 col 5 with detail `includes/missing.md` | `code == .EINCLUDEMISSING`; `source_path == "guides/a.md"`; message contains detail; formatted output contains `EINCLUDEMISSING` and `guides/a.md:3:5` | All strings retain-owned; `formatText` works; line/column present |
| `makeDiagnostic prefers nested locus path` | unit test | Nested locus selection | `fail` with detail `includes/deep.md` and locus `includes/mid.md`; page path `page.md` | `d.source_path == "includes/mid.md"` | `makeDiagnostic` uses locus over caller source_path when non-empty |
| `bodyOfSource strips frontmatter` | unit test | Parser delegation | Source with `---` frontmatter | Body begins with `"Hello body"` | `bodyOfSource` returns `parsed.doc.body` on success |
| `expandIncludes simple nested and cycle` | integration test | Core expansion + cycle + missing | tmpDir with `a.md`→`b.md`; cycle `c.md`↔`d.md`; missing `nope.md`; nested missing via `outer.md` | Expanded text contains `FROM_A`, `FROM_B`, `Start`, `End`, no literal `&#123;&#123;include`; cycle error with non-empty detail; missing error with correct detail and `line == 1`; nested missing attributes locus to `includes/outer.md` at line 2 | Transitive expansion; cycle detection; missing attribution; nested locus propagation |
| `expandIncludes bounds exponential fan-out` | integration test | Budget guardrail | 13-level chain where each level includes the previous twice (2^12 = 4096 logical expansions); budget set to 1 KiB bytes | `error.ExpansionBudgetExceeded`; `budget.bytes <= budget.byte_limit`; `errorCode(error.ExpansionBudgetExceeded) == .EINCLUDECYCLE`; `fail.detail().len > 0` | Byte budget is not exceeded before the error is returned; budget counter is monotone |
| `expandIncludes rejects symlink targets and symlink path components` | integration test (POSIX only) | Symlink rejection in `readSourceAlloc` | tmpDir with `alias.md` → `real.md` symlink; `linked/` → `real/` directory symlink | `error.IncludeMissing` with detail `includes/alias.md` for file symlink; `error.IncludeMissing` with detail `linked/secret.md` for directory symlink | No-follow open policy for both files and directory components |

## Control flow

### `expandIncludes` top-level

```text
expandIncludes(io, content_dir, gpa, arena, body, owner_path, fail_out)
  → expandIncludesWithBudget(…, budget=default)
      → stack.append(gpa, owner_path)
      → expandRecursive(…, body, locus_path="", depth=0)
          loop over body chars:
            fence open/close tracking (no allocation)
            on "{{include ":
              parse path; validate
              stack cycle check
              budget.chargeExpansion()
              out.appendSlice(arena, body[copy_from..start])   // literal prefix
              cache.get(path) or:
                readSourceAlloc(io, content_dir, path, gpa)   // heap alloc
                bodyOfSource(file_bytes)                       // view
                stack.append(gpa, path)
                expandRecursive(nested_body, …, depth+1)      // arena result
                stack.pop()
                cache.put(gpa, arena_key, arena_value)
                defer gpa.free(file_bytes)
              budget.chargeBytes(expanded.len)
              out.appendSlice(arena, expanded)
              copy_from = j; i = j
          out.appendSlice(arena, body[copy_from..])            // trailing literal
          return out.toOwnedSlice(arena)
```


### `collectTransitiveIncludes` dry-run

```text
collectTransitiveIncludes(io, content_dir, gpa, root_body, out_paths, fail_out)
  → walkIncludes(…, root_body, locus_path="", stack, seen, depth=0)
      scanIncludeDirectives(body, gpa, &hits, fail_out, locus_path)
      for each hit:
        stack cycle check → error.IncludeCycle
        dedup check against out_paths
        out_paths.append(allocator.dupe(hit.path))
        skip if seen.contains(hit.path)
        seen.put(hit.path, {})
        readSourceAlloc → file_bytes [gpa]
        defer gpa.free(file_bytes)
        bodyOfSource(file_bytes)
        stack.append(hit.path)
        walkIncludes(nested_body, hit.path, …, depth+1)
        stack.pop()
```


### Error propagation skeleton

```text
expandRecursive detects cycle/missing/budget
  → setFail(fail_out, body, start, path, locus_path)   // fills FailInfo
  → return err

  OR (nested call fails):
  → var nested_fail: FailInfo = .{};
  → expandRecursive(…, &nested_fail) catch |err| {
        _ = stack.pop();
        if (fail_out) |f| f.* = nested_fail;   // copy inline buffers
        return err;
    };
```
