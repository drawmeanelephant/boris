# Feature 1 — ApexMarkdown Unified (archived notes)

**Status:** **Done** (2026-07-15)  
**Campaign:** Chats 1–5 product land · Chat 6 internal review · Chat 7 external audit response  

The root campaign plan (`APEX-Feature1-plan.md`) was retired after ship. Normative
rules live in contracts and pin docs below; this page keeps the campaign intent
as bullets only.

## Intent (what Feature 1 was)

- Link real **[ApexMarkdown/apex](https://github.com/ApexMarkdown/apex)** under a
  **frozen Boris host ABI** (`vendor/apex/apex.h` / `apex-abi.md`) — not
  “yeet Apex for plain cmark-gfm.”
- Default engine mode: **`APEX_MODE_UNIFIED` only** (no `--apex-mode` in this
  campaign).
- Host adapter (`vendor/apex/apex.c`): `apex_render` → Unified
  `apex_markdown_to_html` → copy into host/Whiteboard allocator →
  `apex_free_string`. Never `apex_free` on arena HTML.
- SSG boundary forced off: file includes, plugins, external plugin detection,
  external highlighters.
- **Aside stays Zig** (`aside.zig`); Apex callouts are a separate author syntax.
- Bare CLI stays **IR-first** (Feature 2 out of scope); no IR `schemaVersion` bump.
- CMake is a **compile-time** host tool only; `zig build` remains the entrypoint.

## Landed (Chats 1–7)

- Pin `vendor/apex-markdown` @ **v1.1.11** — [`VENDOR.md`](../../vendor/apex-markdown/VENDOR.md)
- Static link via `scripts/build-apex-markdown.sh` + `build.zig` `linkApex`
- Structural fidelity **U1–U17** (+ goldens on table/footnote/math/callout; U18
  concurrent D4 smoke; U15b callout-in-Aside)
- Hostile isolation: `test-apex-hostile` does not link real Apex
- Linux CI required ASan smoke (`BORIS_REQUIRE_SANITIZE=1`); macOS opt-in
- Reviews: [internal](feature-1-internal-review.md) ·
  [external response](feature-1-external-audit-response.md)

## Where truth lives now

| Doc | Role |
|-----|------|
| [`docs/contracts/apex-abi.md`](../contracts/apex-abi.md) | Host ABI + adapter boundary (normative) |
| [`vendor/apex-markdown/VENDOR.md`](../../vendor/apex-markdown/VENDOR.md) | Pin SHA, build, what is not committed |
| [`docs/STATUS.md`](../STATUS.md) | Living Done status + D2/D3/D4 residuals |
| [`docs/contracts/parallel-rendering.md`](../contracts/parallel-rendering.md) | `--jobs` + Apex D4 residual note |

## Explicit non-goals (still)

- Strategy B (pure `zig cc`, no CMake)
- Full upstream Apex 1800-test suite as product gate
- `--apex-mode` / multi-mode product surface
- HTML as default CLI (Feature 2)
- Trimming vendor tree for bloat (offline pin preferred)

## Gates (still valid)

```bash
zig build
zig build test
zig build test-apex-hostile
zig build test-apex-sanitize   # Linux CI requires real run via BORIS_REQUIRE_SANITIZE=1
./scripts/release-gate.sh
```
