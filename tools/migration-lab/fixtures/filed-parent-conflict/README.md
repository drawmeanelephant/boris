# Filed parent-key conflict / invalid fixture

Synthetic 1+3 first-slice tree for human-review outcomes:

| File | Source parent keys | Expected status |
|------|--------------------|-----------------|
| `changelog/parent-missing.md` | none | `missing` (collection fallback) |
| `releases/parent-conflict.md` | `parent` vs `parentEntry` differ | `conflict` |
| `releases/parent-unsafe.md` | `parentEntry: ../outside` | `invalid` |
| `releases/parent-empty.md` | `parent_entry:` empty | `invalid` |

Never silently chooses among conflicting values. Source is never rewritten.
