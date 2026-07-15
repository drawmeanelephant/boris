# Diagnostics, severity, exit behavior, source locations

**Status:** normative contract — **implemented** by the milestone 6 IR pipeline  
**Emitted by:** `src/diag.zig` (codes), `src/parser.zig` (parse categories),
`src/graph.zig` (graph codes), `src/pipeline.zig` (aggregation + stderr)

---

## Goals

- Machine-readable problem reports for fixtures and tooling
- Stable error **categories** (codes) for tests and docs
- Accurate **source locations** where the issue is in a file
- Predictable **process exit codes** for CI

---

## Severity

| Severity | Meaning | Affects exit? |
|----------|---------|----------------|
| `error` | Contract violation; compile unsuccessful | yes → non-zero |
| `warning` | Suspicious but allowed; compile may succeed | no (exit 0 if no errors) |
| `info` | Informational | no |

v0.1 ships almost all issues as **`error`**. Warnings are reserved; none are
required by acceptance fixtures unless noted later.

---

## Diagnostic object

Used on stderr (text form) and in `build-report.json` (JSON form). Diagnostics
are **not** embedded on `manifest.json` in v0.1.

### JSON fields (key order)

```text
severity, code, message, remediation, sourcePath, line, column, id
```

| Field | Type | Required | Description |
|-------|------|----------|-------------|
| `severity` | string | yes | `error` \| `warning` \| `info` |
| `code` | string | yes | Stable category, e.g. `EDUPLICATEID` |
| `message` | string | yes | Human-readable, single line preferred |
| `remediation` | string | yes | Author guidance; may be empty string |
| `sourcePath` | string \| null | yes | Content-relative path, or null if N/A |
| `line` | integer \| null | yes | **1-based** line in source file; null if N/A |
| `column` | integer \| null | yes | **1-based** column (v0.1: **byte offset within line**); null if N/A |
| `id` | string \| null | yes | Related entity id when known |

### Text form (stderr)

One diagnostic per line:

```text
{severity}: {code}: {sourcePath}:{line}:{column}: {message}
```

When `sourcePath` is null:

```text
{severity}: {code}: {message}
```

When line/column are null but path is set:

```text
{severity}: {code}: {sourcePath}: {message}
```

Examples (actual codes as emitted):

```text
error: EDUPLICATEID: beta.md:1:1: duplicate id "shared" (also alpha.md)
error: EFRONTMATTER: bad.md:2:1: unknown key "category"
error: EPARENTMISSING: orphan.md:1:1: parent "nope" does not exist
error: EPARENTCYCLE: a.md:1:1: parent cycle involving a -> b -> a
```

Sorting for JSON arrays: by (`sourcePath` empty last in practice via empty
string first), then `line`, `column`, `code`, `message` — all ascending.

---

## Error categories (v0.1 closed set)

These codes are the **stable machine-readable categories**. Implementations
must emit exactly these strings (no underscore variants such as `E_DUP_ID`).

| Code | Severity | When | Emitted by |
|------|----------|------|------------|
| `EDUPLICATEID` | error | Two pages would share the same `id` (byte-exact) | `graph.diagnoseDuplicateIds` |
| `EPARENTMISSING` | error | `parent` id not in the page set | `graph.validateTopology` |
| `EPARENTSELF` | error | `parent` equals the page’s own `id` | `graph.validateTopology` |
| `EPARENTNOTTRUNK` | error | `parent` resolves to a Satellite (satellite-of-satellite) | `graph.validateTopology` |
| `EPARENTCYCLE` | error | Cycle in parent edges | `graph.validateTopology` |
| `EFRONTMATTER` | error | Unclosed fence, bad line, unknown key, duplicate key, unsupported syntax, empty/oversize value, invalid status/tags | `parser.parse` → pipeline |
| `EINVALIDUTF8` | error | Source not valid UTF-8, or leading UTF-8 BOM | `parser.parse` → pipeline |
| `EINVALIDPATH` | error | Path or entity id cannot be canonicalized; illegal segments; absolute path; empty / `.` / `..` components; invalid frontmatter `id:`; **or** two pages’ entity ids differ only in letter case (output collision on case-insensitive FS) | scanner / `parser.parse` / `graph.diagnoseDuplicateIds` → pipeline |
| `ECOMPONENT` | error | Aside / component tokenizer failure (unknown PascalCase tag, nested Aside, invalid kind/id, bad attributes, unterminated Aside) | `aside.tokenizeBody` → pipeline |
| `EINCLUDESYNTAX` | error | Malformed `{{include …}}` directive | `include` → HTML compile |
| `EINCLUDEMISSING` | error | Include target path not found / unreadable | `include` → HTML compile |
| `EINCLUDECYCLE` | error | Transclusion cycle among includes (or depth exceeded) | `include` → HTML compile |
| `EREFERENCESYNTAX` | error | Malformed `[[…]]` wiki-link | `wikilink` → HTML compile |
| `EREFERENCEMISSING` | error | Wiki-link target entity id not in the page graph | `wikilink` → HTML compile |
| `EUSAGE` | error | CLI usage / flag error (unknown flag, conflicts, malformed options) | CLI (exit 2; not in build-report) |
| `EIO` | error | I/O or system failure (missing content root, unreadable file, unexpected runtime) | pipeline / CLI (exit 3 when pure I/O) |

### Mapping notes

| Issue class | Primary code |
|-------------|--------------|
| Duplicate frontmatter key | `EFRONTMATTER` |
| Nested mapping / unsupported YAML form | `EFRONTMATTER` |
| Unclosed frontmatter | `EFRONTMATTER` |
| Frontmatter `id:` with `..` or absolute shape | `EINVALIDPATH` |
| Case-only entity id pair (`a` vs `A`) | `EINVALIDPATH` |
| Content root missing | `EIO` |
| Symlink under content root | `EIO` |

Unknown codes must not be invented by the v0.1 compiler without a contract
amendment. Implementations may later **subdivide** messages under the same
category but must keep the `code` string stable.

---

## Source locations

| Issue | Location points to |
|-------|---------------------|
| Duplicate id | First line of the later file in `sourcePath` order (report both paths in `message`) |
| Unclosed frontmatter | Line of opening `---` (1:1) or EOF line |
| Unknown / bad key | Start of that field line |
| Missing parent | Page source (line/column from validation; v0.1 often `1:1`) |
| Cycle | Each involved file (`1:1` in v0.1) with full cycle path in message |
| Encoding | `1:1` of the file |
| Invalid path/id | The offending path or the `id:` field line |

If a precise column is unknown, use column `1`.

---

## Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Success: validation passed; IR written with `ok: true`; zero `error` diagnostics |
| `1` | Content / validation failed: one or more content `error` diagnostics |
| `2` | Usage / CLI error (`EUSAGE`) |
| `3` | I/O or system failure (`EIO`) |

Rules:

1. Exit `0` only if the IR path completed with `ok: true`.
2. Warnings alone do not force non-zero exit.
3. Do not exit `0` if any `error` was emitted, even if some files parsed.
4. `--help` / `-h` exit `0` without scanning content or writing artifacts.
5. Prefer `3` over `1` for pure I/O failures (missing content root, read errors
   classified as `EIO` with `failure: io`).
6. On content failure the pipeline writes `build-report.json` with diagnostics
   and does **not** publish graph-dependent IR; that does **not** make the exit
   code `0`.
7. `--quiet` suppresses **progress** logging and **diagnostic text on stderr**.
   Exit codes, IR/RAG artifacts, and `build-report.json` diagnostics are
   unchanged.

---

## stderr / stdout

| Stream | Content |
|--------|---------|
| **stderr** | Diagnostics (text form); optional progress logs (`boris: load/roll/ignite/reset`) |
| **stdout** | Reserved; v0.1 prints nothing on the success path (progress uses stderr via `std.debug`) |

---

## Fixture coverage

Critical graph and parser error categories have inventory fixtures under
`fixtures/content/invalid/` and contract fixtures under
`docs/contracts/fixtures/`. Pipeline integration tests assert **stable
categories** and non-publication of graph IR on failure.

| Category | Fixture suite |
|----------|---------------|
| `EDUPLICATEID` | `duplicate-id`, `docs/contracts/fixtures/duplicate-ids` |
| `EPARENTMISSING` | `missing-parent`, contract `missing-parent` |
| `EPARENTSELF` | `self-parent`, contract `self-parent` |
| `EPARENTNOTTRUNK` | `satellite-of-satellite` |
| `EPARENTCYCLE` | `cycle`, contract `cycles` / `longer-cycle` |
| `EFRONTMATTER` | `duplicate-key`, `unclosed-frontmatter`, `nested-mapping` |
| `EINVALIDUTF8` | `invalid-utf8` |
| `EINVALIDPATH` | `invalid-path-id`, contract `invalid-id`, contract `case-id-collision` |

`EUSAGE` and `EIO` are CLI/runtime categories; content-tree fixtures do not
cover them except missing content root (`EIO`).

---

## Non-goals

- Language server protocol
- JSON-RPC
