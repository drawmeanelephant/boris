# Fixture: published link fragments (EFRAGMENTMISSING)

`index.md` carries five `#fragment` references. The rendered-output link audit
(`src/link_audit.zig`, shared by `build` and `validate`) checks each resolved
fragment against the target page's rendered element `id` set — every element
`id`, not only headings.

| Case | Reference | Expected |
|------|-----------|----------|
| Live heading anchor | `./guide.md#real-section` → `guide.html#real-section` | clean |
| Non-heading anchor | `./guide.md#custom-anchor` → `guide.html#custom-anchor` (`<div id>`) | clean |
| Renamed anchor | `./guide.md#old-name` → `guide.html#old-name` | `EFRAGMENTMISSING` **warning** |
| Same-document | `#home` → index's own `id="home"` heading | clean |
| External URL | `https://example.com/page#anything` | unchecked |

Both `build` and `validate` exit `0`: the warning is reported and collected
without failing either surface. Nothing is rewritten — the stale `href` is
published as authored.

Normative: `docs/contracts/diagnostics.md` (`EFRAGMENTMISSING`),
`docs/contracts/documentation-links.md`.
