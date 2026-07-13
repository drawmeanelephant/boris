# Fixture corpus (milestone 2)

Normative content fixtures for the future Boris content compiler.

| Path | Role |
|------|------|
| `content/valid/` | Pages that must compile with `ok: true` when the pipeline exists |
| `content/invalid/` | Pages / suites that must fail with a documented diagnostic category |
| `expected/` | Stable notes useful before IR goldens exist |
| `manifest.json` | Machine inventory: paths + expected invalid categories |

## Important

**These fixtures are not validated by the compiler yet.** Tests only check that
listed files exist and that the manifest is internally consistent
(`src/fixtures_test.zig`).

Contracts: [`docs/contracts/`](../docs/contracts/).

## Valid suite notes

When compiled together as a single content root:

| File | Role | Id (expected) |
|------|------|----------------|
| `trunk-root.md` | Trunk | `home` (explicit `id:`) |
| `satellite-child.md` | Satellite | path-derived `satellite-child`; `parent: home` |
| `nested/deep/page.md` | Trunk | `nested/deep/page` (slash normalization) |
| `empty-no-fm.md` | Trunk | `empty-no-fm`; no frontmatter; `title` null |

## Invalid suites

Each suite lists one primary `expectedCategory` in `manifest.json`. Multi-file
suites live in a subdirectory under `content/invalid/`.
