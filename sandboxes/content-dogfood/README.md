# Content dogfood sandbox — START HERE

**You are a content author, not a compiler engineer.**

This folder is a **sandbox** for rebuilding Boris’s sample documentation site.
Your entire world is this directory. If you feel the urge to open `src/`,
`build.zig`, contracts under `docs/contracts/` in the monorepo, or “just fix
the tokenizer,” **stop**. That is out of scope. Fix the Markdown instead.

---

## Your job

Make `content/` inside this sandbox a **high-quality sample docs site** that:

1. Matches product reality: HTML default + ApexMarkdown Unified + Trunk/Satellite.
2. Compiles cleanly under the real Boris binary (verify script below).
3. Shows real Markdown + Aside features without breaking the component tokenizer.
4. Links with **site HTML paths** (`.html`), not raw GitHub `.md` paths.

Read, in order:

1. This file (scope + forbid list)
2. [`AUTHORING.md`](AUTHORING.md) (hard rules — compile fails if you break them)
3. [`PRODUCT-FACTS.md`](PRODUCT-FACTS.md) (CLI and phase truth only)
4. Existing pages under [`content/`](content/) (draft inventory — rewrite freely)

---

## Allowed edits

| Path | OK? |
|------|-----|
| `sandboxes/content-dogfood/content/**/*.md` | **Yes** — primary work |
| `sandboxes/content-dogfood/content/AGENT-DIRECTIVE.txt` | Optional notes only; keep non-`.md` |
| `sandboxes/content-dogfood/layouts/main.html` | **Only** if you must tweak chrome copy/CSS for readability — do **not** invent new markers |
| `sandboxes/content-dogfood/*.md` (this brief) | No need to edit |

## Forbidden (hard)

Do **not** open, edit, “improve,” or redesign:

- `src/**` (Zig compiler, Aside tokenizer, assemble, graph, …)
- `build.zig`, `build.zig.zon`, `vendor/**`
- `docs/contracts/**` (normative contracts — you do not change product law)
- Root `layouts/main.html` (use the copy **in this sandbox** if needed)
- Root `content/` (your working tree is **this** sandbox’s `content/`)
- CI, scripts (except running `verify.sh`), package tooling

**If the compile fails with `ECOMPONENT`, `EFRONTMATTER`, or `EPARENT*`: fix the Markdown.**  
Do not propose compiler changes. Do not search Zig for “how to allow nested asides.”

---

## Layout markers (already shipped — do not invent more)

The sandbox layout supports:

| Marker | Meaning |
|--------|---------|
| `{{content}}` | Page body (required) |
| `{{nav}}` | Full site forest from the graph |
| `{{breadcrumb}}` | Root → current |
| `{{title}}` | Page title |

You do **not** implement these. You only write pages that form a valid graph so
nav looks sensible.

---

## How to verify (from **repo root**)

```bash
# Prefer the sandbox verify script:
./sandboxes/content-dogfood/verify.sh

# Equivalent manual:
./zig-out/bin/boris --quiet \
  --input sandboxes/content-dogfood/content \
  --html-dir sandboxes/content-dogfood/out/dist \
  --html-layout sandboxes/content-dogfood/layouts/main.html

./zig-out/bin/boris --quiet \
  --input sandboxes/content-dogfood/content \
  --out sandboxes/content-dogfood/out/ir

./zig-out/bin/boris --quiet \
  --input sandboxes/content-dogfood/content \
  --rag-dir sandboxes/content-dogfood/out/rag
```

All three must exit **0**. Failures print diagnostics — fix content.

Generated trees under `sandboxes/content-dogfood/out/` are disposable; do not
commit them unless the human asks.

---

## Done when

- [ ] `./sandboxes/content-dogfood/verify.sh` exits 0
- [ ] ≥6 pages, ≥2 trunks, ≥3 satellites
- [ ] No bare `<Aside` / PascalCase tags **outside** fenced code (see AUTHORING.md)
- [ ] CLI docs say HTML is default; RAG is `boris --rag` (not `zig build rag`)
- [ ] Internal links use `.html` paths that exist under the HTML out dir
- [ ] You did **not** touch `src/` or monorepo contracts

---

## Hand-back

When green, tell the human:

1. Summary of the page map (trunks / satellites)
2. `verify.sh` result
3. Any intentional deferrals

The human (or a merge agent) copies sandbox `content/` into root `content/` if
desired. **You do not merge yourself unless asked.**
