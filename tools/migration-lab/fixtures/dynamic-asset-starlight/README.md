# dynamic-asset-starlight fixture

Focused Starlight migration fixture for dynamic JSX/HTML asset attributes.

| Input | Expected migration behavior |
|---|---|
| `src={localBirdImage.src}` | Remove the dynamic value from generated Markdown, emit a readable review comment, and preserve the exact attribute in `boundary_manifest.json` / `link_review.json` |
| `src="image.png"` (present in the fixture) | Preserve the existing static raw-HTML behavior |
| `src="missing.png"` | Preserve the existing missing-static-reference behavior |

The source file must remain unchanged after conversion.
