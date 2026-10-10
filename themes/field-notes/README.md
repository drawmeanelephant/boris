# Field Notes

Restrained blue field notes. Inspired by Pure.css's small footprint; this
sheet is original and is not Pure.css.

- Layouts: `home.html` (`id:index`), `section.html` (`role:trunk`), `main.html`
- Assets: `assets/field-notes.css` (system stack)
- Sample site: [`examples/field-notes-site/`](https://github.com/drawmeanelephant/boris/tree/main/examples/field-notes-site/)
- Accessibility: [`ACCESSIBILITY.md`](ACCESSIBILITY.md)

Build the specimen from a Boris checkout:

```bash
./zig-out/bin/boris \
  --input examples/field-notes-site/content \
  --theme themes/field-notes \
  --layout-rule default id:index themes/field-notes/layouts/home.html \
  --layout-rule default role:trunk themes/field-notes/layouts/section.html \
  --html-dir test-output/field-notes \
  --quiet
```

## Page metadata

Every layout opens the note with `{{page-status}}`, `{{parent}}`, and
`{{tags}}` instead of the flat `{{metadata}}` list: a draft stamp, a
"Filed in" link to the parent, and `#tag` chips. Each piece emits nothing
when the page has no value for it. All three layouts end with
`{{relations}}` ("Related notes") and `{{backlinks}}` ("Referenced by"),
which also emit nothing on a page without semantic relations.

`{{metadata}}` is intentionally absent: the three hooks above render the same
Status / Parent / Tags fields, and the parent becomes a link instead of a raw
id.
