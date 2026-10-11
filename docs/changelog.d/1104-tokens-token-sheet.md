### Changed

- The `tokens` theme is now a token sheet for a design system with its own
  point of view: pages are spec sheets with hairline rules, field-table
  metadata, and a DRAFT stamp on `status: draft`; collections list children
  as a numbered register; the site graph folds into a mono catalog column;
  and the masthead and cover display the stylesheet's own tokens as live
  swatches, type steps, and space bars. Dark mode prints the same set as a
  blueprint. The theme ships a six-sheet "house set" specimen in its README
  in place of the shared calm-documentation copy, and `{{title}}` now names
  the document `<title>` instead of printing the static word "Tokens" on
  every tab. Presentation only — every existing slot is retained, the
  content model and config schema are unchanged, and the published pages
  stay JavaScript-free. See [the Tokens theme](/themes/tokens/README.md).
