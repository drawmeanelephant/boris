# Product facts (do not invent)

Snapshot for sample-content authors. If this disagrees with the human, ask —
do **not** reverse-engineer the Zig sources.

---

## What Boris is

Zig documentation compiler: Markdown in → validated Trunk/Satellite graph →
HTML site (default), JSON IR, or RAG pack. **Not** a Node SSG.

## CLI (Feature 2)

```text
boris                         → HTML under dist/ (DEFAULT)
boris --html / --html-dir D   → same, explicit
boris --out DIR / --no-rag    → JSON IR only
boris --rag / --rag-dir DIR   → RAG corpus only
boris --jobs N / --watch / --incremental  → HTML helpers
```

There is **no** `zig build rag` product step.

```bash
zig build                                    # build the binary (human/CI)
./zig-out/bin/boris --quiet                  # site
./zig-out/bin/boris --out .boris --quiet     # IR
./zig-out/bin/boris --rag --quiet            # RAG
```

In **this sandbox**, always pass `--input` and isolated out dirs — see
[`verify.sh`](verify.sh).

## Engine (Feature 1)

Bodies are **ApexMarkdown Unified** (real engine), not a stub. Showcase tables,
footnotes, task lists, etc. Prefer markdown + Aside over raw HTML dumps.

## Graph

- Trunk: no `parent`
- Satellite: `parent` points at an existing trunk id
- Fail-loud on cycles, missing parent, satellite-of-satellite
- HTML site also validates the graph before publish

## Layout chrome (Feature 6 MVP)

Shipped markers: `{{content}}`, `{{nav}}`, `{{breadcrumb}}`, `{{title}}`.  
In-page heading `{{toc}}` is **not** shipped — do not document it as done.

## Out of scope for this product (do not promise)

- Next/Astro/React as the site compiler
- Unrestricted MDX / JS in content
- Full YAML frontmatter
- Embedded HTTP dev server (use any static server on `dist/`)
- Subprocess markdown (`pandoc`, etc.)
