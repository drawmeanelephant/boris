---
title: Technology & Rationale
parent: index
status: published
tags: [architecture, zig, rationale]
---

# Technology & Rationale

Boris makes specific, deliberate technical choices. This page explains what those choices are, why they were made, and what they mean for you as someone running the tool.

## Core Architectural Pillars

Deterministic Per-Page Scratch
: Per-page arena allocation frees rendering scratch after each page publish. Durable metadata stays in a long-lived `PageDb` for the run. Process RSS is not claimed to be flat.[^arena]

In-Process Apex C ABI
: Markdown rendering is invoked via direct memory pointer calls into vendored ApexMarkdown, eliminating subprocess IPC overhead.[^cabi]

Fail-Loud Graph Freeze
: Parent relationships, supported wiki-links, and transclusion includes are validated before a new publication is committed.

## Why Zig?

Boris is written in Zig 0.16. Zig was chosen for three properties that matter directly to a documentation compiler:

**Deterministic per-page scratch.** Zig has no garbage collector, and Boris
controls its rendering scratch with a per-page arena that is reset after each
page is published. Narrow durable metadata (title, parent, paths) is promoted
into a long-lived `PageDb` for the rest of the run. That is deliberate retained
state — not "no heap between pages" — and Boris does not claim flat process RSS
across large builds.

**Single static binary.** `zig build` produces one self-contained binary with no Node package tree, Python virtualenv, or Ruby gem set to manage. The supported host platforms and release packaging remain deployment concerns; Boris does not promise one binary for every operating system.

**Direct C interop.** Zig calls C code without a binding layer or a separate process. This is critical for ApexMarkdown — see below.

## Why ApexMarkdown?

Markdown rendering is done by ApexMarkdown (a C library) called **in-process** via Zig's C ABI. This is the most consequential architectural choice in Boris.

The alternative — shelling out to a Markdown CLI on each page — adds process spawn overhead, encoding complexity, and a fragile surface where the subprocess might not be available or might behave differently across versions. ApexMarkdown is compiled from source into the Boris binary at build time via CMake and linked as a static library. At runtime it is called via memory pointer — no IPC, no serialization, no subprocess.

ApexMarkdown is an extended Markdown variant (based on cmark-gfm) that adds tables, footnotes, callouts, math, and a range of other authoring-friendly extensions. Boris uses it in **Unified** mode.

## Why a validated content graph?

Most static site generators treat content as a flat file tree — they render each file independently and produce a navigation sidebar by directory enumeration. Boris treats your content as a **directed graph**.

Each page has an optional `parent` key in its frontmatter. Boris builds the full Trunk/Satellite hierarchy from these declarations, validates that every parent reference resolves to a real page, checks for cycles, and verifies that supported wiki-links and includes point at pages that exist. The HTML build performs these checks before publishing new output.

The practical consequence: you cannot accidentally publish a site with a broken parent chain or supported internal wiki-link/include. External URLs and arbitrary raw HTML links are not universally validated. When a validated relationship fails, Boris exits with code `1` and a human-readable diagnostic pointing at the specific page and problem. No partial output is committed.

<Aside kind="info">

This also means the `{{nav}}` sidebar in your HTML layout is produced from the **same frozen, validated graph** used for IR and RAG — not a best-effort directory scan done separately for HTML. HTML, IR, RAG, Context, and `llms.txt` are separate invocations; they stay aligned when generated from the same source revision.

</Aside>

## Why a closed frontmatter grammar?

Boris accepts exactly eight author-facing frontmatter keys: `id`, `title`, `parent`, `status`, `tags`, `relations`, `published_at`, and `summary`. Unknown keys are rejected with `EFRONTMATTER`. This is intentional.

An open frontmatter grammar (full arbitrary YAML) creates ambiguity about which keys are meaningful, accumulates legacy keys silently, and makes it impossible to give confident diagnostics. A closed grammar means every key has a documented meaning, every rejected key gives a clear error, and the frontmatter contract can be versioned and evolved deliberately.

## Why zero client-side JavaScript runtime?

Boris outputs plain HTML and CSS. There is no required JavaScript bundle, no hydration step, and no client-side rendering. The output works without JavaScript enabled.

The one optional JavaScript feature is the search UI — a small script that
fetches the compiler-owned `search-index.json` and renders results. It is a
theme concern: the default layout includes it, while a custom layout must
provide its own consumer. The static index and no-JavaScript fallback do not
require a build tool or bundler.

## Why a single-source multi-output model?

Generating HTML, JSON IR, RAG, Context Bundle, and `llms.txt` from the same validated graph keeps those editions aligned **when they are produced from the same source revision**. Each mode is a separate invocation: the HTML navigation matches the IR graph from that revision, the RAG corpus lists the same published pages, and `llms.txt` reflects that published state.

If each output format used a different content model, they would drift. Boris solves the structural half by validating the graph once per invocation and routing the frozen graph to the requested emitter. Cross-mode alignment is an operational choice (same source revision), not a single multi-writer transaction.

## Summary

| Choice | Reason |
|---|---|
| Zig | Explicit scratch control, single binary, direct C interop |
| ApexMarkdown in-process | No subprocess overhead; consistent across builds |
| Validated content graph | Breaks loudly before publishing, not silently after |
| Closed frontmatter grammar | Every key has a defined meaning; rejections are diagnostic |
| No required client JS runtime | Works everywhere; no build toolchain needed |
| Single-source multi-output | Same graph model per mode; align by generating from one revision |

[^arena]: Per-page arena allocation frees rendering scratch after each page publish. Durable `PageDb` metadata is retained for the run. Process RSS is not claimed.
[^cabi]: Direct C ABI binding links ApexMarkdown directly into the host Zig executable, executing markdown transformation in-memory without child processes.
