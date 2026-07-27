---
title: Getting Started
status: published
tags: [setup, quickstart, cli]
---

# Getting Started with Boris

Boris is a zero-dependency static documentation compiler written in Zig. You write clean Markdown files with explicit page relationships (`parent` and wiki-links), and Boris validates your documentation graph before emitting static HTML, a client-side search index, JSON IR, RAG packages, AI Context Bundles, and `llms.txt`—all from a single fast, native binary with no JavaScript runtime or Node.js toolchain required.

<Aside kind="info">

**Layer 1 Summary:** Boris takes Markdown files in `content/`, validates parent references and links, and writes static HTML and AI machine packages to disk. No Node.js, no bundlers, no runtime dependencies.

</Aside>

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

Complete your first useful action in under 5 minutes without reading any compiler source code:

### Step 1: Render the Corporate HTML Site
```bash
./zig-out/bin/boris --theme examples/prototype-corporate --html-dir dist
```
*Outcome:* Boris scans `content/`, parses frontmatter, validates parent graph hierarchy, and emits responsive HTML files to `dist/` with graph-backed sidebar navigation.

### Step 2: Generate the Client-Side Search Index
```bash
zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search
```
*Outcome:* The search index tool reads rendered HTML under `dist/` and writes `dist/_boris/search/search-index.json`.

### Step 3: Export AI & Machine Packages
```bash
./zig-out/bin/boris --rag --rag-dir dist/rag --quiet
./zig-out/bin/boris --out dist/.boris --quiet
./zig-out/bin/boris --llms --llms-path dist/llms.txt --quiet
./zig-out/bin/boris --context --context-dir dist/context --quiet
```
*Outcome:* Creates `dist/rag/` (Markdown RAG corpus), `dist/.boris/` (JSON IR), `dist/llms.txt`, and `dist/context/` (AI Context Bundle) from the exact same frozen content graph.

### Step 4: Validate Without Publishing
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
**Reality:** Boris compiles HTML deterministically without bundling a JavaScript engine. To enable search, run `zig build --build-file tools/search-index/build.zig run -- --root=./dist --out=./dist/_boris/search` after HTML rendering.

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
