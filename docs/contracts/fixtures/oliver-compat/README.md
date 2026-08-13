# Oliver renderer compatibility fixture

**Read-only audit** of the Markdown constructs Boris publishes, as rendered by
the pinned Oliver library through the `src/render.zig` seam.

- Pin and upgrade procedure: [`../../oliver-renderer.md`](../../oliver-renderer.md)
- Canonical renderer contract: [`../../oliver-renderer.md`](../../oliver-renderer.md)
- Heading-id contract: [`../../heading-ids.md`](../../heading-ids.md)

| File | Role |
|------|------|
| [`MATRIX.md`](MATRIX.md) | Compatibility matrix (classifications) |
| `content/` | Construct probes rendered by `src/render.zig`'s unit tests and the html fixture goldens |

## Classifications

1. **supported and tested** — rendered by Oliver through the seam and pinned by
   `zig build test-render` and/or the html fixture goldens
2. **supported but unverified** — Oliver supports it (CommonMark conformance)
   but no durable Boris fixture pins the exact bytes
3. **not rendered (deliberate)** — Apex-only extension that Oliver does not
   provide; removed from the published surface, documented in
   `oliver-renderer.md`'s compatibility wall

This tree is not a second spec. On any conflict the contract docs and tests
win.
