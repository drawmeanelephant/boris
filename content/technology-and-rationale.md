---
title: Technology & Rationale
parent: index
status: published
tags: [architecture, zig, rationale]
---

# Technology & Rationale

Boris makes specific, deliberate technical choices. This page explains what those choices are, why they were made, and what they mean for you as someone running the tool.

## Core Architectural Pillars

Deterministic Memory
: Per-page arena allocation ensures scratch memory is freed upon page reset, keeping total RSS flat throughout long build runs.[^arena]

In-Process Apex C ABI
: Markdown rendering is invoked via direct memory pointer calls into vendored ApexMarkdown, eliminating subprocess IPC overhead.[^cabi]

Fail-Loud Graph Freeze
: Parent relationships, wiki-links, and transclusion includes are validated before any output file is written to disk.

## Why Zig?

Boris is written in Zig 0.16. Zig was chosen for three properties that matter directly to a documentation compiler:

**Deterministic memory.** Zig has no garbage collector and no hidden allocations. Boris controls its own memory precisely — per-page arena allocation for rendering scratch, explicit free at page reset, and no retained heap state between pages. This means memory usage stays flat even when building large sites.

**Single static binary.** `zig build` produces one self-contained binary with no runtime dependencies. Users do not need to manage a Node package tree, a Python virtualenv, or a Ruby gem set. The binary runs on macOS and Linux without installation.

**Direct C interop.** Zig calls C code without a binding layer or a separate process. This is critical for ApexMarkdown — see below.

## Why ApexMarkdown?

Markdown rendering is done by ApexMarkdown (a C library) called **in-process** via Zig's C ABI. This is the most consequential architectural choice in Boris.

The alternative — shelling out to a Markdown CLI on each page — adds process spawn overhead, encoding complexity, and a fragile surface where the subprocess might not be available or might behave differently across versions. ApexMarkdown is compiled from source into the Boris binary at build time via CMake and linked as a static library. At runtime it is called via memory pointer — no IPC, no serialization, no subprocess.

ApexMarkdown is an extended Markdown variant (based on cmark-gfm) that adds tables, footnotes, callouts, math, and a range of other authoring-friendly extensions. Boris uses it in **Unified** mode.

## Why a validated content graph?

Most static site generators treat content as a flat file tree — they render each file independently and produce a navigation sidebar by directory enumeration. Boris treats your content as a **directed graph**.

Each page has an optional `parent` key in its frontmatter. Boris builds the full Trunk/Satellite hierarchy from these declarations, validates that every parent reference resolves to a real page, checks for cycles, and verifies that wiki-links and includes point at pages that exist. This validation runs **before any output file is written**.

The practical consequence: you cannot accidentally publish a site with a broken page reference. Boris exits with code `1` and a human-readable diagnostic pointing at the specific page and the specific problem. No partial output is committed.

<Aside kind="info">

This also means the `{{nav}}` sidebar in your HTML layout is produced from the **same frozen, validated graph** used for IR and RAG — not a best-effort directory scan done separately for HTML. All outputs are consistent by construction.

</Aside>

## Why a closed frontmatter grammar?

Boris accepts exactly five author-facing frontmatter keys: `id`, `title`, `parent`, `status`, and `tags`. Unknown keys are rejected with `EFRONTMATTER`. This is intentional.

An open frontmatter grammar (full arbitrary YAML) creates ambiguity about which keys are meaningful, accumulates legacy keys silently, and makes it impossible to give confident diagnostics. A closed grammar means every key has a documented meaning, every rejected key gives a clear error, and the frontmatter contract can be versioned and evolved deliberately.

## Why zero client-side JavaScript runtime?

Boris outputs plain HTML and CSS. There is no required JavaScript bundle, no hydration step, and no client-side rendering. The output works without JavaScript enabled.

The one optional JavaScript feature is the search UI — a small inline script that fetches `search-index.json` and renders results. It is opt-in (you include it in your layout), degrades gracefully (the navigation still works without it), and requires no build tool or bundler.

## Why a single-source multi-output model?

Generating HTML, JSON IR, RAG, Context Bundle, and `llms.txt` from the same validated graph means these outputs are **always consistent**. The HTML navigation matches the IR graph. The RAG corpus contains the same pages as the HTML site. The `llms.txt` file reflects the current published state.

If you changed the content model for each output format separately, they would drift. Boris solves this by running graph validation once and then routing the frozen, validated graph to whichever output format you requested.

## Summary

| Choice | Reason |
|---|---|
| Zig | Deterministic memory, single binary, direct C interop |
| ApexMarkdown in-process | No subprocess overhead; consistent across builds |
| Validated content graph | Breaks loudly before publishing, not silently after |
| Closed frontmatter grammar | Every key has a defined meaning; rejections are diagnostic |
| No required client JS runtime | Works everywhere; no build toolchain needed |
| Single-source multi-output | All outputs are consistent with each other by construction |

[^arena]: Per-page arena allocation ensures that memory scratch space allocated while parsing a page is freed immediately upon page reset, keeping total RSS flat throughout long build runs.
[^cabi]: Direct C ABI binding links ApexMarkdown directly into the host Zig executable, executing markdown transformation in-memory without child processes.
