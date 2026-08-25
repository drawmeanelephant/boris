---
title: Emoji Kitchen prototype cases
---

# Ordinary text

This is eligible: !ek[🐢+🔥]. Malformed stays literal: !ek[🐢+]. Unsupported
text stays literal: !ek[cat+🔥]. Too many operands stay literal:
!ek[🐢+🔥+✨].

# Inline contexts

## Emphasis and links

*Emphasis !ek[🐢+🔥].*

[A link label !ek[🐢+🔥]](https://example.test/guide)

## Lists, quotes, and tables

- List item !ek[🐢+🔥]

> Blockquote !ek[🐢+🔥]

| Kind | Value |
| --- | --- |
| table cell | !ek[🐢+🔥] |

## Code must remain literal

Inline code: `!ek[🐢+🔥]`

```markdown
# Fence
!ek[🐢+🔥]
```

## Destinations and raw HTML must remain literal

[Destination](https://example.test/!ek[🐢+🔥])

![Image destination](images/!ek[🐢+🔥].png)

<span data-note="!ek[🐢+🔥]">Raw HTML !ek[🐢+🔥]</span>

The future adapter must not turn playful source syntax into provenance,
creator, or other factual metadata.
