# Project status — Boris milestone 10 (v0.1 harden)

**As of:** 2026-07-13 (product **0.0.1** / compiler **boris/0.1.1** IR + RAG + Aside + Apex + experimental HTML)  
**Zig target:** 0.16.0 (`build.zig.zon` / CI pin **0.16.0**)

This file is the living **“where we are”** note. Prefer it (and
[`CHANGELOG.md`](../CHANGELOG.md)) over archaeology in git history when
starting a session.

---

## One-line product (current phase)

**Boris v0.1 ships a single-threaded content compiler** with validated JSON IR,
optional deterministic RAG (including `:::kind` Aside export), constrained
`<Aside>` tokenization on the shared compile path, and an experimental HTML
render path (Apex + Whiteboard + layout splice). Default CLI is still IR or RAG
only — HTML is library/test surface, not default product mode.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| **Implemented & tested** | Covered by `zig build test` / release gate on CI |
| **Platform-qualified** | Behavior depends on host OS/FS; not overclaimed |
| **Vendor contract** | Relies on Apex C ABI assumptions (not fully Zig-provable) |
| **Intentionally deferred** | Explicit non-goal for v0.1 |

---

## What works today

| Capability | Status | Notes |
|------------|--------|--------|
| `zig build` → `boris` executable | **Implemented & tested** | Apex C linked in-process |
| Typed CLI (`--input`, `--out`, `--rag`, …) | **Implemented & tested** | Exit 0/1/2/3 |
| Deterministic scanner | **Implemented & tested** | Sort by entity id; symlink reject |
| Canonical identity + safe output paths | **Implemented & tested** | No `..` escape |
| Bounded frontmatter parser | **Implemented & tested** | Not YAML |
| Aside component tokenizer | **Implemented & tested** | `src/aside.zig`; `ECOMPONENT` |
| Graph validate + freeze (shared IR/RAG) | **Implemented & tested** | One entry point |
| Deterministic JSON IR | **Implemented & tested** | `.boris/` staging publish |
| Optional RAG + `:::kind` Aside export | **Implemented & tested** | Non-round-trippable export form |
| Apex C ABI + Zig wrapper | **Implemented & tested** | Hostile + opt-in sanitizer |
| Experimental HTML + Aside stream | **Implemented & tested** | Not default CLI |
| CI matrix Linux + macOS | **Implemented & tested** | GitHub Actions |
| HTML `dist/` default CLI | **Intentionally deferred** | Modules/tests only |
| Full YAML / MDX / concurrency / watch | **Intentionally deferred** | See non-goals |

### How to run

```bash
zig build
zig build test
zig build test-apex-hostile
zig build test-apex-sanitize   # opt-in; skips cleanly if unavailable
zig build run -- --help
zig build run -- --input fixtures/content/valid --out /tmp/boris-ir
zig build run -- --input fixtures/content/valid --rag-dir /tmp/boris-rag
zig build run -- --input docs/contracts/fixtures/valid/content --out .boris
zig build source-rag
./scripts/release-gate.sh
```

### Shared pipeline surface

```text
Load  → scanner.scan
Roll  → parser.parse + aside.tokenizeBody + PageDb.promote
Ignite → graph.validate (+ freeze when clean)
         + IR JSON emit  OR  RAG corpus export
Reset → retain arena lifetime ends with Result.deinit
```

**Experimental HTML:**

```text
Layout load → PageDb promote → per page:
  Whiteboard → parse/tokenize → Apex + Aside HTML → writePage → free_all
```

Exit codes: `0` success, `1` content, `2` usage, `3` I/O.

---

## Platform-qualified behavior

- Symlink unit tests skipped on Windows / when symlink create is denied
- IR/RAG publication: staging + rename/copy; **not** whole-tree atomic replace;
  cross-volume atomicity **not** claimed
- HTML Atomic replace: same-directory rename; multi-OS CI covers Linux + macOS
  unit tests, not every filesystem
- Cross-OS bit-identical RAG/IR trees **not** claimed beyond dual-run tests on
  each CI host

## Vendor contract / assumptions (Apex)

- Synchronous `apex_render`; no retained pointers after return
- Custom allocator path; never `apex_free` on whiteboard HTML
- Stub engine is a **minimal** markdown subset — not CommonMark
- Hostile double tests mechanical wrapper rules; full C non-retention against
  arbitrary engines remains a contract (see `docs/contracts/apex-abi.md`)

## Intentionally deferred

- Default CLI HTML `dist/` product mode
- Markdown-native `:::` **authoring** (export representation only)
- Nested asides, multi-component registry, MDX
- Incremental rebuild / reverse dependency index
- Concurrency / worker pools / watch mode / mmap
- Process RSS flatness claims

---

## Documentation map

| Doc | Role |
|-----|------|
| `README.md` | Human front door |
| `AGENTS.md` | Hard constraints |
| `docs/contracts/` | Normative contracts |
| `docs/contracts/components.md` | **Aside tokenizer (m10)** |
| `docs/AUDIT-v0.1.md` | Self-audit report |
| `docs/rag/system/` | Narrative seeds (RAG system segment) |
| `CHANGELOG.md` | What changed |
| This file | Living status |

---

## Identity metaphor (narrative → code)

| Teaching beat | Current mapping |
|---------------|-----------------|
| **Load** | `scanner.scan` |
| **Roll** | frontmatter + Aside tokenize + PageDb promote + graph classify |
| **Ignite** | validate + freeze + emit IR or RAG; experimental HTML write |
| **Reset** | IR/RAG: arena deinit; HTML: Whiteboard `free_all` per page |

Namesake = folk Zouave improviser known as Boris — independent homage, **not**
affiliated with any commercial tobacco / rolling-paper brand. Do **not** invent
branded component names (no “Broside”).
