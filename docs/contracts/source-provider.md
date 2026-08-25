# Source provider

**Status:** normative for [#301](https://github.com/drawmeanelephant/boris/issues/301) M1  
**Module:** [`src/source_provider.zig`](../../src/source_provider.zig)  
**Related:** [scanner.md](scanner.md), [includes-and-wiki-links.md](includes-and-wiki-links.md), [identity-and-paths.md](identity-and-paths.md)

The compiler reads author input through two operations:

1. **enumerate** canonical page paths in scanner order
2. **read** a named content-root-relative source

This is not a virtual filesystem. There is no cwd, `stat`, `mkdir`, or
directory cookie.

## Adapters

| Adapter | Role |
|---|---|
| `Dir` | Native CLI default. Walks a host directory with the existing scanner and `source_io` / include no-follow reads. |
| `Memory` | Embedding / tests. A canonical list of `{path, bytes}`. No host directory. |

`pipeline.compile` uses `Dir` when `CompileOptions.sources` is null. A
caller may pass `Memory` instead. Existing fixture tests keep using the
filesystem adapter.

## Memory bundle rules

- Paths are content-root-relative and must survive `identity.canonicalize`
  (`/` separators, no `..`, no absolute paths).
- Duplicate canonical paths are rejected at init (`DuplicatePath`).
- Page discovery uses the same extension, `includes/` reservation, and
  `.assets` skip rules as [scanner.md](scanner.md).
- Files under `includes/` are readable as include sources and are never
  pages.
- `readPage` applies the same oversized-source bound as `source_io.readPageAlloc`.

## What this does not cover

Theme, layout, and content-local asset reads stay on `Io.Dir` until M4.
The HTML `compile.zig` path is unchanged in this card.
