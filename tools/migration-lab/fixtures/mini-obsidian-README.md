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
| `Notes/Suffix Probe.md` | Ambiguous path-suffix `[[Shared Path/Deep]]` |
| `Ambiguous/Shared.md` + `Other/Shared.md` | Basename collision for `[[Shared]]` |
| `Projects/Q1 Plan.md` | Spaces in path/name |
| `Embeds.md` | Asset embed, note embed, block ref |
| `Dataview Demo.md` | Dataview / plugin-style syntax (report only) |
| `Canvas Board.canvas` | Canvas (unsupported inventory) |
| `Attachments/diagram.png` | Local image attachment |
| `Vault/Concept Board/…` | Path-suffix resolution (`[[Concept Board/…]]` without `Vault/`) |
| `A/Shared Path/Deep.md` + `B/Shared Path/Deep.md` | Ambiguous path-suffix pair |
| `Clash/Hello World.md` + `Clash/Hello-World.md` | Entity-id collision → unique `-2` remap |
| `Templates/Nav.md` | Templater / `${…}` wiki targets → `plugin_template` |
| `.obsidian/` | Must be ignored |
| `node_modules/` | Must be ignored |

## Expected conversion signals

- Unambiguous `[[Beta]]` / `[[Notes/Beta]]` rewrite to Boris entity ids
- Path-suffix `[[Concept Board/Concept Board]]` → `[[Vault/Concept-Board/Concept-Board|…]]`
- `[[Shared]]` → ambiguous (human review; raw retained)
- `[[Shared Path/Deep]]` → ambiguous path-suffix (raw retained)
- `[[Missing Note]]` → unresolved (human review; raw retained)
- `[[Beta#Section]]` / block refs → heading/block review (raw retained)
- `[[${navLink}\|…]]` / `[[<% … %>]]` → `plugin_template` (not unresolved)
- `![[Attachments/diagram.png]]` → ordinary Markdown image when unique
- `Hello World` / `Hello-World` clash → two output files (`Hello-World`, `Hello-World-2`)
- Dataview / Canvas / plugin markers → report, never silent drop
- Two runs → byte-identical `report.json` / `REPORT.md` / manifests **and** generated content pages
- Source vault bytes unchanged after import
