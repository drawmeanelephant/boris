# Diagnostics, severity, exit behavior, source locations

**Status:** normative contract for future compiler implementation  
**Milestone:** 2 (contracts + fixtures). The default CLI does **not** emit these
diagnostics yet (milestone 1 ships only usage / help).

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

Examples:

```text
error: EDUPLICATEID: guides/intro.md:1:1: duplicate id "guides/intro" (also content/guides/intro.md)
error: EFRONTMATTER: bad.md:2:1: unknown key "category"
error: EPARENTMISSING: tips.md:3:1: parent "nope" does not exist
error: EPARENTCYCLE: a.md:1:1: parent cycle involving a -> b -> a
```

Sorting for JSON arrays: by (`sourcePath` nulls last), then `line`, `column`,
`code`, `message` — all ascending with nulls last for paths.

---

## Error categories (v0.1 closed set)

These codes are the **stable machine-readable categories**. Implementations
must emit exactly these strings (no underscore variants such as `E_DUP_ID`).

| Code | Severity | When |
|------|----------|------|
| `EDUPLICATEID` | error | Two pages would share the same `id` (byte-exact) |
| `EPARENTMISSING` | error | `parent` id not in the page set |
| `EPARENTSELF` | error | `parent` equals the page’s own `id` |
| `EPARENTNOTTRUNK` | error | `parent` resolves to a Satellite (satellite-of-satellite) |
| `EPARENTCYCLE` | error | Cycle in parent edges |
| `EFRONTMATTER` | error | Unclosed fence, bad line, unknown key, duplicate key, unsupported syntax, empty/oversize value, invalid status/tags |
| `EINVALIDUTF8` | error | Source not valid UTF-8, or leading UTF-8 BOM |
| `EINVALIDPATH` | error | Path or entity id cannot be canonicalized; illegal segments; absolute path; empty / `.` / `..` components |
| `EUSAGE` | error | CLI usage / flag error (unknown flag, conflicts, malformed options) |
| `EIO` | error | I/O or system failure (filesystem, permissions, unexpected runtime outside content validation) |

### Mapping notes

| Issue class | Primary code |
|-------------|--------------|
| Duplicate frontmatter key | `EFRONTMATTER` |
| Nested mapping / unsupported YAML form | `EFRONTMATTER` |
| Unclosed frontmatter | `EFRONTMATTER` |
| Frontmatter `id:` with `..` or absolute shape | `EINVALIDPATH` |
| Content root missing | `EIO` (or `EUSAGE` if surfaced as bad CLI path — prefer `EIO` when the path string was well-formed but unusable) |

Unknown codes must not be invented by the v0.1 compiler without a contract
amendment. Implementations may later **subdivide** messages under the same
category but must keep the `code` string stable.

---

## Source locations

| Issue | Location points to |
|-------|---------------------|
| Duplicate id | First line of the second file discovered in sort order by `sourcePath` (report both paths in `message`) |
| Unclosed frontmatter | Line of opening `---` (1:1) or EOF line |
| Unknown / bad key | Start of that field line |
| Missing parent | Start of the `parent` field line |
| Cycle | `parent` field of each involved file, or primary file with full cycle in message |
| Encoding | `1:1` of the file |
| Invalid path/id | The offending path or the `id:` / `parent:` field line |

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

1. Exit `0` only if the IR path completed with `ok: true` (or, when implemented,
   optional RAG export succeeded without content errors).
2. Warnings alone do not force non-zero exit.
3. Do not exit `0` if any `error` was emitted, even if some files parsed.
4. `--help` / `-h` exit `0` without scanning content or writing artifacts.
5. Prefer `3` over `1` for pure I/O failures that are not represented as content
   diagnostics.
6. On content failure the pipeline should still write `build-report.json` with
   diagnostics when it can; that does **not** make the exit code `0`.

**Milestone 3 CLI (current implementation):** exit `0` (help or valid-mode
stub), `2` (usage/flag conflicts), and `3` (arg allocation / process I/O
failures at the entry point). Code `1` is reserved until the content pipeline
emits validation diagnostics.

---

## stderr / stdout

| Stream | Content |
|--------|---------|
| **stderr** | Diagnostics (text form); optional progress logs must not interleave mid-line with diagnostics in fixtures |
| **stdout** | Reserved; v0.1 may print nothing or a single success summary |

---

## Fixture coverage

Critical graph and parser error categories have inventory fixtures under
`fixtures/content/invalid/` and are listed in `fixtures/manifest.json`.
Fixture tests verify **inventory and manifest consistency only** until the
compiler validates them.

| Category | Fixture suite (see manifest) |
|----------|------------------------------|
| `EDUPLICATEID` | `duplicate-id` |
| `EPARENTMISSING` | `missing-parent` |
| `EPARENTSELF` | `self-parent` |
| `EPARENTNOTTRUNK` | `satellite-of-satellite` |
| `EPARENTCYCLE` | `cycle` |
| `EFRONTMATTER` | `duplicate-key`, `unclosed-frontmatter`, `nested-mapping` |
| `EINVALIDUTF8` | `invalid-utf8` |
| `EINVALIDPATH` | `invalid-path-id` |

`EUSAGE` and `EIO` are CLI/runtime categories; they are not represented as
content-tree fixtures.

---

## Non-goals

- Language server protocol
- JSON-RPC
- Soft “continue on error” multi-file partial IR for v0.1 success path
  (implementations may parse all files to collect diagnostics, but must not
  claim success or write full success IR)
