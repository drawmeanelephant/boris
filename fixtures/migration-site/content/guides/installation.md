---
title: Installation
parent: guides
status: published
tags: [guides, setup]
---

# Installation

Boris is a Zig project. There is no npm install and no language runtime in the
publish path.

## Host tools

| Tool | When needed |
|------|-------------|
| Zig 0.16 | Always (build + run) |
| CMake | Compile time only (Apex static libs) |

## Clone and build

```bash
git clone https://github.com/drawmeanelephant/boris.git
cd boris
zig build
```

The product binary lands at `./zig-out/bin/boris`.

## Verify

```bash
./zig-out/bin/boris --help
zig build test
```

Next: [[guides/getting-started|compile a site]].
