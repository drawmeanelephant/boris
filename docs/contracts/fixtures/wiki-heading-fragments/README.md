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
| Unicode / punctuation ids | target page headings as rendered by Oliver |
| UTF-8 entity id (#883) | `guides/café.md` linked from index as `[[guides/café]]` |
| Duplicate heading id | `[[guides/target#dup]]` is valid (set membership) |

Normative: `docs/contracts/heading-ids.md`.
