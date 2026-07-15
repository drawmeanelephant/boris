---
title: Getting Started with Boris
status: published
tags: [setup, cli]
---
# Getting Started

Ready to ignite your docs? Let's get Boris running.

## Prerequisites

- **Zig 0.16+**
- **CMake** (required at compile-time for the Apex Markdown C ABI)

## Installation & First Build

1. **Clone the repo**
   ```bash
   git clone https://github.com/your-org/boris.git
   cd boris
   ```
2. **Build Boris**
   ```bash
   zig build
   ```
3. **Build the Demo Site**
   ```bash
   ./zig-out/bin/boris --quiet
   ```
   *Your site is now available in `dist/`!*

## Run Modes

Boris has three primary run modes to fit your workflow:

| Mode | Command | Output | Use Case |
|------|---------|--------|----------|
| **HTML (Default)** | `./zig-out/bin/boris` | `dist/` | Standard static site generation. |
| **JSON IR** | `./zig-out/bin/boris --out .boris` | `.boris/` | Machine-readable Intermediate Representation. |
| **RAG Corpus** | `./zig-out/bin/boris --rag` | `rag/` | AI-ready product RAG packaging. |

<Aside kind="tip">
You can also use `--watch` and `--jobs N` for faster, incremental HTML builds during authoring!
</Aside>
