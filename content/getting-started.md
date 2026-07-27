---
title: Getting Started
status: published
tags: [setup, quickstart, cli]
---

# Getting Started with Boris

Boris is a zero-dependency static documentation compiler written in Zig. You write clean Markdown files with explicit page relationships (`parent` and wiki-links), and Boris validates your documentation graph before emitting static HTML. Optional machine packages (JSON IR, RAG, AI Context Bundles, and `llms.txt`) use the same native binary in separate invocations. Client-side search indexing is a separate standalone Zig tool that reads the rendered HTML.

<Aside kind="info">

**Layer 1 Summary:** Boris takes Markdown files in `content/`, validates parent references and supported internal links, and writes static HTML (or an optional machine package) to disk. No Node.js, no bundlers, no runtime dependencies for the core compiler.

</Aside>

{{include includes/shared-tip.md}}

## Prerequisites & Building

Building Boris requires two standard tools:

- **Zig 0.16+** — the compiler language Boris is written in ([ziglang.org](https://ziglang.org/download/)).
- **CMake** — used once at compile time to build the vendored ApexMarkdown static library.

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
```

The compiled binary is written directly to `./zig-out/bin/boris`.

---

## 5-Minute Concrete Value Path (Layer 2)

Complete your first useful action in under 5 minutes:

### Step 1: Render the HTML Site
```bash
./zig-out/bin/boris
```
*Outcome:* Boris scans `content/`, parses frontmatter, validates parent graph hierarchy, and emits responsive HTML files to `dist/` with graph-backed sidebar navigation.

### Step 2: Open in Browser
Open `dist/index.html` in your web browser for a first look at the generated site. Navigation, breadcrumbs, and reading work over `file://`. Client-side search needs a real HTTP origin at the site root (or a configured URL prefix) plus the search index from Branch A below — see [[guides/search-and-ui|Search & Browser UI]].

---

## Optional Build Branches

### Branch A: Add Client-Side Search
```bash
zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search
```
*Outcome:* The search index tool reads rendered HTML under `dist/` and writes `dist/_boris/search/search-index.json`.

### Branch B: Export Machine & AI Packages
```bash
./zig-out/bin/boris --rag --rag-dir dist/rag --quiet
./zig-out/bin/boris --out dist/.boris --quiet
./zig-out/bin/boris --llms --llms-path dist/llms.txt --quiet
./zig-out/bin/boris --context --context-dir dist/context --quiet
```
*Outcome:* Creates `dist/rag/` (Markdown RAG corpus), `dist/.boris/` (JSON IR), `dist/llms.txt`, and `dist/context/` (AI Context Bundle) from the exact same frozen content graph.

### Branch C: Validate Graph Without Writing Files
```bash
./zig-out/bin/boris check
```
*Outcome:* Validates all page parent chains, wiki-links, and includes in memory without writing any files to disk. Exit code `0` confirms clean validation.

---

## Common Hesitations & Misconceptions (Developer & Agent Ore)

Every mistaken assumption when discovering a new tool is documentation ore. Here are the most frequent hesitation points:

<Aside kind="warning">

### Gotcha 1: Output modes are mutually exclusive
**Hesitation:** Running `./zig-out/bin/boris --rag --out .boris` expecting both HTML, RAG, and IR in one invocation.  
**Reality:** Output modes (`--rag`, `--out`, `--llms`, `--context`, default HTML) are **mutually exclusive per invocation**. Run separate commands to generate all outputs.

</Aside>

<Aside kind="warning">

### Gotcha 2: Search indexing is decoupled from HTML rendering
**Hesitation:** Running `./zig-out/bin/boris` and opening `dist/index.html`, then wondering why search returns no results.  
**Reality:** The default HTML compiler does not emit the search index. After HTML rendering, run `zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search`. Search also needs an HTTP origin that can fetch the index relative to the rendered site root; plain `file://` browsing is fine for reading pages but not for the search UI.

</Aside>

<Aside kind="warning">

### Gotcha 3: Accepted frontmatter keys are strictly closed
**Hesitation:** Adding custom YAML frontmatter fields like `author: Jane`, `date: 2026-07-27`, or using legacy names like `parentEntry`.  
**Reality:** Boris enforces a closed frontmatter contract of exactly 5 allowed keys: `id`, `title`, `parent`, `status`, and `tags`. The parent key **must be `parent` only**. Any extra key raises `EFRONTMATTER` and halts the build.

</Aside>

<Aside kind="warning">

### Gotcha 4: Broken links stop the build before writing output
**Hesitation:** Expecting a partial website build when a page contains an unresolvable wiki-link target or invalid parent.  
**Reality:** Boris executes **Load → Roll → Ignite → Reset**. Graph validation (Roll phase) happens *before* any output file is written (Ignite phase). If validation fails, Boris exits with code `1` and a diagnostic message—no broken site is ever published.

</Aside>

---

## Next Steps

- [[guides/overview|Content Model & Pipeline]] — Understand Trunk & Satellite pages, graph validation, and pipeline stages.
- [[guides/cli-and-modes|CLI & Output Modes]] — Learn about watch mode, `--jobs` parallelism, and output paths.
- [[guides/search-and-ui|Search & Themes]] — Customizing layouts, marker tokens, and search UI.
- [[reference/commands|CLI Reference]] — Full breakdown of flags, options, and exit codes.
