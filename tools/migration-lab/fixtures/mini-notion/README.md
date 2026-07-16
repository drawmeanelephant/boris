# mini-notion — synthetic Notion Markdown & CSV export fixture

Public, deterministic fixture for `boris-migration-lab --mode=notion`.
**Not** a real workspace export; no private Notion data. No API credentials.

Page filenames follow Notion’s `Title <32-hex-id>.md` convention (hex ids only).

## Layout

| Path | Role |
|------|------|
| `Home …aaaa.md` | Root page; links, image, missing, ambiguous basename |
| `Home …/Nested Guide …bbbb.md` | Nested page + local attachment link |
| `Home …/Nested Guide …/Deep Page …cccc.md` | Three-level nesting (deep hierarchy review) |
| `Home …/Nested Guide …/diagram.png` | Local attachment |
| `Home …/Shared Name …f0f0.md` + `Other Root …/Shared Name …2222.md` | Basename collision for `Shared Name.md` |
| `Home …/Tasks Database …dddd.csv` | Database CSV (unsupported inventory) |
| `Home …/Tasks Database …/Row Alpha …eeee.md` | Database row page |
| `Properties Demo …3333.md` | Relation/rollup, synced block, embed, unsupported block |
| `With Frontmatter …4444.md` | Compatible FM + unknown key |
| `node_modules/` | Must be ignored |

## Expected conversion signals

- Unambiguous nested page link → `[[Home/Nested-Guide]]`
- Attachment → rewritten path under `media/` and listed in `media_manifest.json`
- `Shared Name.md` → ambiguous (human review; raw retained)
- Missing page → unresolved (human review; raw retained)
- Database CSV → `unsupported_items` / `database_csv` (never silent drop)
- Relation/rollup/synced/embed/unsupported block → hazards + human review
- Deep page → `deep_hierarchy` human review
- Two runs → byte-identical reports, manifest, and generated content
- Source export bytes unchanged after import
