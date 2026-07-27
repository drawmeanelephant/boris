---
title: CLI & Output Modes
parent: getting-started
status: published
tags: [cli, guides]
---

# CLI & Output Modes

Boris provides a clean, single-binary CLI surface. This guide covers output modes, parallel execution, watch mode, and CLI exit codes.

<Aside kind="info">

**Layer 1 Summary:** Running `./zig-out/bin/boris` without flags emits static HTML to `dist/`. Passing `--out`, `--rag`, `--context`, or `--llms` selects a specific machine export mode. Modes are mutually exclusive.

</Aside>

---

## Output Modes Summary

| Desired Output | Command Line | Primary Flag | Default Location |
|---|---|---|---|
| **Static HTML Site** | `./zig-out/bin/boris` | Default | `dist/` |
| **Custom Theme HTML** | `./zig-out/bin/boris --theme examples/prototype-corporate` | `--theme` | `dist/` |
| **JSON IR Graph** | `./zig-out/bin/boris --out .boris` | `--out` | `.boris/` |
| **RAG Corpus** | `./zig-out/bin/boris --rag --rag-dir dist/rag` | `--rag` | `rag/` |
| **AI Context Bundle** | `./zig-out/bin/boris --context --context-dir dist/context` | `--context` | `context/` |
| **`llms.txt` Index** | `./zig-out/bin/boris --llms --llms-path dist/llms.txt` | `--llms` | `llms.txt` |
| **Check Graph Only** | `./zig-out/bin/boris check` | `check` subcommand | None (Memory only) |

---

## HTML Build Flags

```bash
# Render with custom output folder
./zig-out/bin/boris --html-dir public

# Render with parallel workers (up to 64 jobs)
./zig-out/bin/boris --jobs 4 --quiet

# Watch mode for authoring (automatically re-renders changed pages)
./zig-out/bin/boris --watch --quiet

# Incremental build mode (skips unchanged pages based on hash)
./zig-out/bin/boris --incremental --quiet
```

---

## Conflict Rules & Exit Codes

Output modes cannot be combined in a single invocation. Attempting to pass conflicting mode flags (e.g. `--out` and `--rag` together) exits immediately with code `2` (usage error).

### Standard Exit Codes:
- `0` — Success. All pages parsed, validated, and rendered cleanly.
- `1` — Content or Graph Error (`EFRONTMATTER`, `EPARENTMISSING`, `EREFERENCEMISSING`, `EINCLUDEMISSING`, …). Validation failed; no files written.
- `2` — CLI Usage Error. Invalid flag combination or bad argument.
- `3` — I/O or System Error. Cannot read `content/` directory or write output.

---

## Next Steps

- [[getting-started|Getting Started]] — 5-minute quickstart guide.
- [[reference/commands|CLI Reference]] — Complete flag dictionary and options.
