# Oliver compatibility matrix (through the Boris seam)

Pin: Oliver `42cf472b635f8cbe9dad0da081b830f5db21c745` (see
[`oliver-renderer.md`](../../oliver-renderer.md)). Classification legend in
[`README.md`](README.md).

| Construct | Class | Boris evidence |
|-----------|-------|----------------|
| Paragraphs | supported and tested | `test-render`; html goldens |
| ATX headings + auto-ids | supported and tested | `test-render`; `compile.zig` golden `L<h1 id="alpha">…` |
| Setext headings | supported and tested | `test-render` |
| Heading IALs (`{#id .class}`) | supported and tested | `test-render`; `content/reference/commands.md` |
| Emphasis / strong | supported and tested | `test-render` |
| Inline links | supported and tested | html goldens |
| Reference links | supported and tested | html goldens |
| Images (inline/reference) | supported and tested | `test/fixtures/doc-links` |
| Code spans | supported and tested | `test-render` |
| Fenced code (+ language class) | supported and tested | `test-render`; html goldens |
| Indented code | supported and tested | html goldens |
| Block quotes | supported and tested | `aside.zig` U15b |
| Ordered/unordered/nested lists | supported and tested | html goldens |
| Thematic breaks | supported and tested | html goldens |
| Entities | supported and tested | `test-render` (`&amp;`) |
| Autolinks | supported and tested | html goldens |
| Raw inline HTML | supported and tested | `test/fixtures/doc-links` |
| HTML blocks | supported and tested | html goldens |
| GFM tables | supported and tested | `test-render`; html goldens |
| Hard/soft breaks | supported and tested | html goldens |
| Escaping | supported and tested | html goldens |
| Unicode | supported and tested | `test-render` (Café résumé) |
| Footnotes (`[^label]` + defs) | supported and tested | `test-render`; `content/technology-and-rationale.md` |
| Definition lists (`Term` + `: def`) | supported and tested | `test-render`; `content/technology-and-rationale.md` |

Deliberately not rendered (Apex-only extensions, not used by published content):

| Construct | Note |
|-----------|------|
| Math (`$…$`, `$$…$$`) | removed with the old renderer |
| Callouts (`> [!NOTE]`) | now ordinary blockquotes |
| Task lists (`- [ ]`) | removed |
| Fenced divs (`:::`) | removed |
| Bracket spans `[text]{IAL}` | removed |
| Critic markup | removed |
| Smart typography | source bytes kept literal |
| Image/table captions (`figure`/`figcaption`) | plain `<p><img>` / `<table>` |
| Strikethrough (`~~x~~`) | supported and tested | `test-render`; `ext-strikethrough` fixture upstream; Textile `-deleted-` contract |
