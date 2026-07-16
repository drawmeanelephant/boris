# Fixture: wiki heading fragments (success shape)

Author content illustrating valid `[[entity-id#heading-id]]` forms. Not an IR
golden; HTML integration tests exercise the same patterns.

| Case | Example |
|------|---------|
| Page-only (regression) | `[[guides/target]]` |
| Fragment auto-id | `[[guides/target#section-one]]` |
| Label + fragment | `[[guides/target#code-x-y\|Code heading]]` |
| From satellite | `guides/from.md` → `[[index#home]]` |
| Include-borne wiki | fragment in `includes/blurb.md` |
| Unicode / punctuation ids | target page headings as rendered by Apex |
| Duplicate heading id | `[[guides/target#dup]]` is valid (set membership) |

Normative: `docs/contracts/heading-ids.md`.
