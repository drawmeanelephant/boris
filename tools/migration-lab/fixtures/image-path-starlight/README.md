# image-path-starlight fixture

Regression fixture for **F-L1** Starlight Markdown image path resolution.

| Case | Source | Expected lab behavior |
|------|--------|------------------------|
| Relative sibling | `features/alpha.mdx` → `./img/shot.png` with asset at `features/img/shot.png` | Copy → `alpha.assets/img/shot.png`, rewrite Markdown |
| Nested | `nested/deep/page.mdx` → `./media/pic.png` | Copy → `page.assets/media/pic.png` |
| Missing | `missing/page.mdx` → `./nope.png` | Leave unre-written; `referenced_asset_missing` review |
| Escape | `escape/page.mdx` → `../../../../secret.png` | Leave unre-written; `asset_path_escapes_migration_root` |
| Already-correct | `ready/note.mdx` → `note.assets/ok.png` | Preserve ref form; copy bytes to out sibling tree |
| Public absolute | `features/alpha.mdx` → `/images/hero.png` | Copy from `public/images/hero.png` into page assets when proven |

Not a universal importer; covers the resolve → `{stem}.assets/` rewrite surface only.

**Compile note:** a whole-tree `boris` run of the lab output is expected to
**fail** on the intentional missing/escape pages (`EASSET`). The happy subset
(features + nested + ready + trunks) compiles after migration. Dogfood-scale
proof is `fixtures/dogfood-starlight/` → `compile_report.status=ok`.
