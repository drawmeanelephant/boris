# mini-obsidian — synthetic Obsidian vault fixture

Public, deterministic fixture for `boris-migration-lab --mode=obsidian`.
**Not** a real vault export; no private notes.

## Layout

| Path | Role |
|------|------|
| `Welcome.md` | Trunk-like home; unambiguous wiki links |
| `Notes/Alpha.md` | Links to Beta, Gamma, alias, heading ref, missing |
| `Notes/Beta.md` | Simple target |
| `Notes/Sub/Gamma.md` | Nested path target |
| `Ambiguous/Shared.md` + `Other/Shared.md` | Basename collision for `[[Shared]]` |
| `Projects/Q1 Plan.md` | Spaces in path/name |
| `Embeds.md` | Asset embed, note embed, block ref |
| `Dataview Demo.md` | Dataview / plugin-style syntax (report only) |
| `Canvas Board.canvas` | Canvas (unsupported inventory) |
| `Attachments/diagram.png` | Local image attachment |
| `.obsidian/` | Must be ignored |
| `node_modules/` | Must be ignored |

## Expected conversion signals

- Unambiguous `[[Beta]]` / `[[Notes/Beta]]` rewrite to Boris entity ids
- `[[Shared]]` → ambiguous (human review; raw retained)
- `[[Missing Note]]` → unresolved (human review; raw retained)
- `[[Beta#Section]]` / block refs → heading/block review (raw retained)
- `![[Attachments/diagram.png]]` → ordinary Markdown image when unique
- Dataview / Canvas / plugin markers → report, never silent drop
- Two runs → byte-identical `report.json` / `REPORT.md` / manifests
- Source vault bytes unchanged after import
