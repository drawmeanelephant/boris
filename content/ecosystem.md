---
title: "The Stack: Oliver, Boris, Solipsist"
parent: index
status: published
tags: [ecosystem, oliver, solipsist, start-here]
summary: Three projects, one pipeline. Oliver renders markup, Boris compiles sites from it, Solipsist is the Mac app that drives Boris.
---

<p class="eyebrow">Start here</p>

# The Stack {#the-stack}

Three projects, each usable on its own, stacked so that each one builds on
the one below it. Pick the layer you need: you do not have to adopt the
others.

```text
Solipsist   native macOS app                 ← you click
    │       runs `boris` as a subprocess, reads its JSON
    ▼
Boris       publication compiler             ← you run `boris`
    │       calls Oliver in-process as a Zig library
    ▼
Oliver      markup library                   ← you embed it
            Markdown · Textile · Cooklang → typed document → HTML
```

| I want to… | Use | Site | Source |
| :--- | :--- | :--- | :--- |
| Turn markup into HTML inside my own program | **Oliver** | [Oliver docs](https://drawmeanelephant.github.io/oliver/) | [GitHub](https://github.com/drawmeanelephant/oliver) |
| Build and publish a website from Markdown | **Boris** | [Boris docs](https://drawmeanelephant.github.io/boris/) (you are here) | [GitHub](https://github.com/drawmeanelephant/boris) |
| Write and publish from a Mac app instead of a terminal | **Solipsist** | [solipsist.filed.fyi](https://solipsist.filed.fyi) | [GitHub](https://github.com/drawmeanelephant/solipsist) |

## Oliver — the markup library {#oliver}

Oliver is a small, freestanding markup library written in Zig. You give it
bytes of Markdown, Textile, or Cooklang; it gives back a typed document (or,
for Cooklang, a typed recipe) and, when you ask, deterministic HTML or XHTML.
Same input, same bytes out, every time. It touches no filesystem, network,
clock, or threads, so it embeds cleanly anywhere. It ships as a Zig library,
a command-line tool, and a stable C ABI for other languages. Its Markdown
passes all 652 examples of the CommonMark 0.31.2 specification. Use Oliver
directly if you are building your own tool and only need markup in, HTML out.

[Oliver documentation](https://drawmeanelephant.github.io/oliver/) ·
[Oliver on GitHub](https://github.com/drawmeanelephant/oliver)

## Boris — the publication compiler {#boris}

Boris is the compiler this site documents, and the compiler that built it.
Point it at a folder of Markdown pages; it reads each page's small, closed
frontmatter, links pages into a validated graph (every page names at most one
`parent`), and refuses to build if a link or parent is broken. Then it writes
a static HTML site to `dist/`. The same graph can also publish to GitHub
Pages or Standard.site, or export JSON IR, RAG and context packs, RSS, and a
sitemap. Boris renders every page body by calling Oliver in-process — no
subprocess, no Node toolchain. Use Boris if you want a site, docs, a blog, or
a cookbook built from plain files by one native binary.

[[getting-started|Getting Started]] ·
[Boris on GitHub](https://github.com/drawmeanelephant/boris)

## Solipsist — the Mac app {#solipsist}

Solipsist is a native macOS workstation, written in SwiftUI, for people who
would rather publish from a window than a terminal. Open a folder of Boris
content and the whole loop — sources, page graph, publication plan, build,
live preview, publish — lives in one Mail-style window, with Plan, Validate,
and Build as real menu items. Solipsist does not reimplement the compiler:
it runs the `boris` binary as an isolated subprocess and reads its JSON
contracts, so what you see is exactly what Boris would do on the command
line. There is no notarized download yet; today you build it from source.
Use Solipsist if you are on a Mac and want Boris with a native interface.

[solipsist.filed.fyi](https://solipsist.filed.fyi) ·
[Solipsist on GitHub](https://github.com/drawmeanelephant/solipsist)

<Aside kind="note" id="stack-boundaries">

Each layer only talks to the one below it through a published surface:
Boris pins an exact Oliver revision in `build.zig.zon`, and Solipsist pins
a Boris build and its JSON contracts. None of them reaches up the stack, so
you can adopt Oliver without Boris, or Boris without Solipsist.

</Aside>
