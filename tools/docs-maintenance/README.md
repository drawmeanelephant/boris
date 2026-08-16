# Standalone Boris Documentation Maintenance Tool (`boris-docs-maintenance`)

`boris-docs-maintenance` is a standalone developer tool inside the Boris repository (under `tools/docs-maintenance/`) that inventories documentation evidence, validates source dossier markers, and publishes deterministic status reports (`inventory.json` and `summary.md`).

## Architecture & Boundary

- **Isolated Tool Shell**: Lies strictly outside the core `boris` static site compiler binary and root `build.zig`.
- **Read-Only Evidence**: Treats repository source code, tests, contracts, dossiers, and notes as strictly read-only.
- **Output Tree**: Writes report artifacts solely to `zig-out/docs-maintenance/` (or explicitly requested `--json` / `--markdown` paths) using sibling temporary replacement (`.tmp` write followed by atomic rename).
- **Zero Shell/Process Execution**: Reads and inspects files natively in Zig in-process without spawning external shell or process calls.

## Usage

### Run Scan via Zig Build
```bash
zig build --build-file tools/docs-maintenance/build.zig run
```

### Run Unit and Fixture Tests
```bash
zig build --build-file tools/docs-maintenance/build.zig test
```

### Build Executable Binary
```bash
zig build --build-file tools/docs-maintenance/build.zig
./tools/docs-maintenance/zig-out/bin/boris-docs-maintenance scan --help
```

### CLI Options
```
USAGE:
  docs-maintenance scan [OPTIONS]

OPTIONS:
  --repo <path>          Repository root path (default: .)
  --source-root <path>   Source root relative to repo (default: src)
  --dossier-root <path>  Optional dossier claim root (default: docs/boris/src).
                         The product no longer ships a dossier tree; a missing
                         directory is skipped. Use this flag for a local
                         analysis tree if you have one.
  --json <path>          Output JSON inventory path (default: zig-out/docs-maintenance/inventory.json)
  --markdown <path>      Output Markdown summary path (default: zig-out/docs-maintenance/summary.md)
  -h, --help             Display this help message
```

## Inventory Classification & Grammar

- Evidence set paths are normalized with `/` relative to the repository root.
- Dossier markers follow strict ASCII grammar:
  ```markdown
  <!-- BORIS-SOURCE-DOC BEGIN path="src/example.zig" -->
  Dossier content...
  <!-- BORIS-SOURCE-DOC END path="src/example.zig" -->
  ```
- Rejects nested, unterminated, or mismatched markers (`EDOSSIER_MARKER`).
- Rejects dossiers claiming multiple distinct source files (`EMULTI_SOURCE_DOSSIER`).
- Records skipped symlinks deterministically (`WSYMLINK_SKIPPED`).
- Computes a length-prefixed raw evidence-set digest tagged with `boris-docs-evidence-set-v0\0`.
