---
rag_id: system/name-and-metaphor
rag_path: system/10-name-and-metaphor.md
category: system
tags: [boris, name, metaphor, load, roll, ignite, reset, identity]
related:
  - system/00-overview.md
  - system/01-architecture-pipeline.md
  - system/03-trunk-and-satellite.md
  - system/05-memory-whiteboard.md
  - system/07-zero-copy-assembly.md
---

# Name and metaphor

This seed is **narrative**, not a machine contract. Normative IR rules live under
`docs/contracts/`. Nothing here changes emit shape, exit codes, or validation.

## Who “Boris” is (project naming)

The project is named after **Boris**: the bearded **Zouave** figure from
nineteenth-century French light-infantry folklore — the calm improviser of
trench and siege stories who, when his clay pipe is shattered under fire, rolls
loose tobacco in whatever paper he has and keeps going.

That figure later became a widely recognized folk mascot (often just called
“Boris,” “the Captain,” or “the Zouave”) in popular culture. **This software
project is an independent homage to that character and temperament.** It is
**not** affiliated with, endorsed by, or a product of any rolling-paper company,
tobacco brand, apparel line, or their trademarks, logos, package trade dress, or
marketing campaigns. We do not use third-party brand names as product branding
here.

If you already know that folk Boris, you already know the vibe we mean: **cool
under pressure, practical, chain-ready, wipe the slate and do the next one.**

## Temperament → engineering taste

| Folk temperament | Compiler preference |
|------------------|---------------------|
| Improvisation under constraint | Prefer **splice and stream** over rebuilding giant intermediates |
| Interleaved chain (pull one, next presents) | **Bottom-up** edges: satellites declare parentage; reverse links assemble in memory |
| Tools at the belt, not a second camp | **Asides / components stay in document order** — not standalone fragment pages |
| Clear the trench, next volley | **Whiteboard arena** `reset` / `free_all` after each page (HTML path) |
| One calm figure, no circus staff | **Zig monolith** first; no Node SSG stack in the critical path |

## Load · Roll · Ignite · Reset

Teaching names for the compile rhythm. They map to real phases; they are not
CLI flags and not IR field names.

```text
LOAD   → gather sources (discover / scan / identity)
ROLL   → shape the payload (frontmatter, body split, graph freeze)
IGNITE → fire the work (validate, emit IR / RAG / opt-in HTML)
RESET  → free page scratch; next page starts clean
```

### Load

Bring the content set into a known order. Deterministic walk of `content/`,
canonical entity ids, no mid-compile rediscovery. Leaves on the table before
anyone lights anything.

### Roll

Form the compact payload authors actually meant:

- Closed frontmatter grammar (not full YAML)
- Body split and optional component tokens
- Trunk / Satellite graph: **children name parents** (bottom-up foreign keys)
- Freeze validated relations before emit

“Roll” is interleaving made abstract: pulling a satellite should not leave an
orphan story — parent context is part of the chain the compiler resolves.

### Ignite

Do the irreversible-looking work only after shape and validation:

| Surface | Ignite means |
|---------|----------------|
| v0.1 default | Emit deterministic JSON under `.boris/` |
| Optional | Package product RAG under `rag/` |
| Opt-in HTML | Apex render + zero-copy layout writes to `dist/` (or multi-target roots) |

Ignite is **not** “spawn a markdown process farm.” When markdown becomes HTML,
Apex is in-process C ABI.

### Reset

After a page (or unit of work) finishes:

- Document-local arena returns to empty capacity on the HTML whiteboard path
- No hanging parse slices promoted onto long-lived `Page` state
- Next page does not inherit the previous page’s scratch

On the v0.1 IR path, “reset” is lighter (less per-page render scratch) but the
discipline is the same: **deterministic finish, no leftover intermediate soup.**

## Analog map (quick reference)

| Metaphor | Prefer this language in docs | Avoid |
|----------|------------------------------|--------|
| Folk Zouave / Boris | Project namesake, temperament | Implying brand ownership or official product tie-in |
| Load → Roll → Ignite → Reset | Pipeline teaching rhythm | Inventing CLI modes named after the metaphor |
| Interleaved chain | Bottom-up parent edges, reverse index | Trademarked package product names |
| Improvised splice | Zero-copy prefix \| body \| suffix | “Bypass Astro / hand off to JS SSG” framing |
| Tools on the belt | Aside, admonition, registered component | Branded component names (e.g. “Broside”) |
| Clear the trench | Whiteboard / `ArenaAllocator` reset | Claiming lock-free shared mutable pools beyond documented `--jobs` isolation |

## Status honesty

Metaphors describe **intent and long-term shape**. Current milestone status lives
in `docs/STATUS.md`. Bare CLI remains IR-first; opt-in HTML uses whiteboard +
zero-copy assemble (with bounded `--jobs` workers and optional `--watch`). Do not
treat this seed as a claim that every stage is fully wired on every CLI mode, or
that Apex is CommonMark-complete.

## One-sentence summary for retrieval

Boris the compiler is named for the folk Zouave improviser known as Boris:
**load** sources, **roll** a validated Trunk/Satellite payload, **ignite**
deterministic emit (IR, optional RAG, opt-in HTML), **reset** page scratch
and go again — independent software, not a commercial brand extension.
