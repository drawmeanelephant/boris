# Project status — Boris milestone 5

**As of:** 2026-07-13 (product **0.0.1** parser + discovery + CLI surface + contracts)  
**Zig target:** 0.16.0 (`build.zig.zon` / CI pin **0.16.0**)

This file is the living **“where we are”** note. Prefer it (and
[`CHANGELOG.md`](../CHANGELOG.md)) over archaeology in git history when
starting a session.

---

## One-line product (current phase)

**Boris milestone 5 ships a strict, bounded frontmatter parser and Markdown
body splitter** (library surface + fixture tests). The default CLI still stubs
the full pipeline (does not scan or parse on every invocation until later
wiring). Graph IR and product RAG remain future work.

---

## What works today

| Capability | Status | Notes |
|------------|--------|--------|
| `zig build` → `boris` executable | **Shipped** | `zig-out/bin/boris` |
| Typed CLI options | **Shipped** | m3: `--input`, `--out`, `--rag`, … |
| Deterministic scanner | **Shipped** | `src/scanner.zig` — `.md`/`.mdx`, sorted, symlink reject |
| Canonical identity | **Shipped** | `src/identity.zig` — single `canonicalEntityId` |
| Discovery `Page` metadata | **Shipped** | `src/page.zig` — paths/id + frontmatter view types |
| Bounded frontmatter parser | **Shipped** | `src/parser.zig` — not YAML; body split; source views |
| `zig build test` | **Shipped** | CLI + fixtures + scanner/identity + **parser** + source-rag |
| Normative contracts | **Shipped (docs)** | + [frontmatter.md](contracts/frontmatter.md) precision |
| Fixture corpus | **Shipped** | Inventory + exercised by parser fixture tests |
| Source RAG tool | **Shipped** | `zig build source-rag` |
| Frontmatter on default CLI | **Not wired** | library only until pipeline milestone |
| Parent graph / JSON IR | **Not started** | |
| Product RAG export | **Not started** | |
| Apex / HTML assemble | **Not started** (default product) | |

### How to run

```bash
zig build
zig build test                     # includes parser + scanner + identity tests
zig build run -- --help
zig build source-rag
```

### Parser (library surface)

```text
const r = parser.parse(source_bytes);
// r.isOk() / r.category() → EFRONTMATTER | EINVALIDUTF8 | EINVALIDPATH
// r.doc.meta.* and r.doc.body are views into source_bytes
```

BOM: **rejected** (`EINVALIDUTF8`). Line endings: LF and CRLF.  
Absent title: `null` (no derivation from headings or filename).

---

## Documentation map

| Doc | Role |
|-----|------|
| `README.md` | Human front door |
| `AGENTS.md` | Hard constraints |
| `docs/contracts/` | Normative contracts |
| `docs/contracts/frontmatter.md` | Bounded FM grammar, bounds, ownership |
| `docs/contracts/scanner.md` | Discovery walk + symlink policy |
| `docs/contracts/identity-and-paths.md` | Id/path rules |
| `docs/rag/system/` | Narrative seeds (incl. name / Load·Roll·Ignite·Reset) |
| `fixtures/` | Content fixture corpus |
| `CHANGELOG.md` | What changed |
| This file § To be implemented | Forward notes to fold into code later |

---

## Known gaps (expected at m5)

- Default CLI does not yet invoke the scanner or parser (pipeline stub from m3)
- No graph validation, IR emit, or product RAG on the default CLI
- Symlink unit tests skipped on Windows / when symlink create is denied
- Experimental modules under `src/` (compile/harness/HTML path) may still assume
  a richer pre-m4/m5 surface; they are not the default product surface

---

## To be implemented / roll forward

Living scratch for product work still ahead. Not contracts. Append notes here as
they arrive; fold into modules/contracts when a milestone actually lands them.

### Pipeline wiring (m6+)

- Wire scanner + parser into the default CLI (`pipeline.run`, not stub)
- Parent graph validation + freeze
- Deterministic JSON IR under `.boris/` (`manifest`, `graph`, `build-report`)
- Optional product RAG export (`--rag`) against contracts
- HTML/Apex assemble remains experimental until explicitly promoted

### Identity metaphor (narrative → code over time)

Seed already drafted: [`docs/rag/system/10-name-and-metaphor.md`](rag/system/10-name-and-metaphor.md).
**More notes will land here.** Prefer rolling metaphors into real surfaces
gradually (docs first, then comments/log language, never trademarked branding).

| Teaching beat | Target meaning when implemented |
|---------------|----------------------------------|
| **Load** | Discover / scan / identity — deterministic content set |
| **Roll** | Frontmatter + body shape + bottom-up Trunk/Satellite graph freeze |
| **Ignite** | Validate + emit IR / optional RAG / experimental HTML (in-process Apex) |
| **Reset** | Whiteboard arena `free_all` per page on HTML path; clean finish on IR path |

**Constraints while rolling this in:**

- Namesake = folk Zouave improviser known as Boris — independent homage, **not**
  affiliated with any commercial tobacco / rolling-paper brand or their marks.
- Do **not** invent branded component names (no “Broside”); use Aside / admonition / component.
- Do **not** frame the product as a pre-processor for Astro/Next or any JS SSG.
- Do **not** claim multi-thread / zero-lock pools until the monolith is correct and STATUS says so.
- Load/Roll/Ignite/Reset are teaching names, not CLI flags or IR field names, unless a later design deliberately promotes them.

**Private drop:** local `SUPPORT/` is gitignored (scratch images/notes). Not
source of truth; do not commit it.
