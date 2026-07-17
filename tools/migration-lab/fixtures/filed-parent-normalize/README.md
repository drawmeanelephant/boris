# Filed parent-key normalization fixture (happy path)

Synthetic 1+3 first-slice tree covering safe parent rewrites only:

| File | Source parent keys | Expected status |
|------|--------------------|-----------------|
| `changelog/parent-entry-camel.md` | `parentEntry: changelog` | `normalized` |
| `releases/parent-entry-snake.md` | `parent_entry: releases` | `normalized` |
| `releases/parent-canonical.md` | `parent: releases` | `identity` |
| `releases/parent-both-same.md` | `parent` + `parentEntry` same value | `normalized` |

Conflict / invalid cases live in [`../filed-parent-conflict/`](../filed-parent-conflict/).
Not a Filed.fyi export; public redistributable only.
