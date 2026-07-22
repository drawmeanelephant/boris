# Emoji Kitchen portability prototype

This is a **non-rendered contract fixture** for the proposed optional Emoji
Kitchen adapter. It is intentionally not part of the default product behavior
or release-gate corpus yet: current Boris has no local pair manifest or
combined-image asset set.

The source cases in `content/index.md` establish the cases a future adapter
must distinguish before it is wired into the HTML path:

| Case | Expected future behavior |
| --- | --- |
| ordinary text | eligible for validated `!ek[left+right]` recognition |
| heading/emphasis/link label/list/blockquote/table | eligible when the surrounding Markdown parser exposes inline text |
| inline code/fenced code | remain literal, byte-for-byte |
| link or image destination | remain literal; never rewrite URLs |
| malformed/unsupported operands | remain literal, fail closed |
| raw HTML/tag attributes | remain literal; no HTML-string replacement |
| escaping-sensitive operands | derive escaped labels/assets through normal Markdown/HTML paths |

No generated HTML is checked in. A future implementation should add a golden
fixture only after the manifest, output mode, accessibility text, and asset
ownership contract are frozen.
