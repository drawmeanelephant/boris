# Diagnostics, severity, exit behavior, source locations

**Status:** normative contract — core implemented; Feature 8 extends existing
include/reference categories to IR dependency resolution without adding codes
**Emitted by:** `src/diag.zig` (codes), `src/parser.zig` (parse categories),
`src/graph.zig` (graph codes), `src/pipeline.zig` / `src/compile.zig`
(aggregation + stderr)

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

v0.2 ships almost all issues as **`error`**. Warnings are reserved; none are
required by acceptance fixtures unless noted later.

---

## Diagnostic object

Used on stderr (text form) and in `build-report.json` (JSON form) when the
selected IR projection emits that report. `boris validate` uses the same text
form, ordering, and exit classes but writes no report or artifact. Diagnostics
are **not** embedded on `manifest.json` in v0.2.

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
| `column` | integer \| null | yes | **1-based** column (v0.2: **byte offset within line**); null if N/A |
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

## Error categories (v0.3 closed set)

These codes are the **stable machine-readable categories**. Implementations
must emit exactly these strings (no underscore variants such as `E_DUP_ID`).

v0.3 adds `EROUTEMISSING`, `EROUTEESCAPE`, and `EFRAGMENTMISSING` for the
published-output link audit. Every v0.2 code keeps its exact spelling and
meaning, so a consumer written against v0.2 stays correct; it will encounter
codes it does not recognize only on a build that publishes a local reference the
site cannot serve.

| Code | Severity | When | Emitted by |
|------|----------|------|------------|
| `EDUPLICATEID` | error | Two pages would share the same `id` (byte-exact) | `graph.diagnoseDuplicateIds` |
| `EPARENTMISSING` | error | `parent` id not in the page set | `graph.validateTopology` |
| `EPARENTSELF` | error | `parent` equals the page’s own `id` | `graph.validateTopology` |
| `EPARENTNOTTRUNK` | retired | Historical one-hop contract; no longer emitted for hierarchical parent chains | — |
| `EPARENTCYCLE` | error | Cycle in parent edges | `graph.validateTopology` |
| `EFRONTMATTER` | error | Unclosed fence, bad line, unknown key, duplicate key, unsupported syntax, empty/oversize value, invalid status/tags | `parser.parse` → pipeline |
| `EINVALIDUTF8` | error | Source not valid UTF-8, or leading UTF-8 BOM | `parser.parse` → pipeline |
| `EUNICODE` | error | Source contains a code point with no legitimate authoring use: a control character, a Unicode noncharacter, a deprecated format control, an interlinear annotation, a bidi embedding/override (U+202A–U+202E), an unclosed bidi isolate, an interior U+FEFF, or a tag character outside an emoji subdivision-flag sequence | `parser.parse` → pipeline |
| `EUNICODE` | warning | Source contains invisible characters in a shape that reads as smuggling — a run of three or more, or zero-width characters interleaved between ASCII letters. Advisory only: ZWJ, ZWNJ, ZWSP, word joiner and soft hyphen are load-bearing in emoji sequences and in Persian, Indic and CJK text, so they are reported and never rewritten | `parser.parse` → pipeline |
| `EINVALIDPATH` | error | Path or entity id cannot be canonicalized; illegal segments; absolute path; empty / `.` / `..` components; invalid frontmatter `id:`; **or** two pages’ entity ids differ only in letter case (output collision on case-insensitive FS) | scanner / `parser.parse` / `graph.diagnoseDuplicateIds` → pipeline |
| `ETEXTILE` | error | Explicit Textile input-family mismatch, unsupported Textile feature, malformed supported syntax, or unsafe Textile link | scanner / `textile.toMarkdown` → pipeline / HTML |
| `ECOMPONENT` | error | Aside / component tokenizer failure (unknown PascalCase tag, nested Aside, invalid kind/id, bad attributes, unterminated Aside) | `aside.tokenizeBody` → pipeline |
| `EINCLUDESYNTAX` | error | Malformed `{{include …}}` directive | `include` → HTML / IR dependency resolution |
| `EINCLUDEMISSING` | error | Include target path not found / unreadable | `include` → HTML / IR dependency resolution |
| `EINCLUDECYCLE` | error | Transclusion cycle among includes (or depth exceeded) | `include` → HTML / IR dependency resolution |
| `EREFERENCESYNTAX` | error | Malformed `[[…]]` wiki-link (including empty or illegal `#` fragment) | `wikilink` → HTML / IR dependency resolution |
| `EREFERENCEMISSING` | error | Wiki-link target entity id not in the page graph, **or** `#fragment` not among that page’s rendered heading ids | `wikilink` → HTML / IR dependency resolution |
| `ERELATIONMISSING` | error | Semantic relation target entity id is not in the page graph | shared semantic relation validation before graph freeze |
| `ERELATIONSELF` | error | Semantic relation targets its source page | shared semantic relation validation before graph freeze |
| `ERELATIONDUPLICATE` | error | Same semantic `(kind,target)` tuple appears more than once | parser / shared semantic relation validation before graph freeze |
| `EASSET` | error | Content-local page asset path invalid, outside the owning page’s sibling tree, missing, symlink, not a regular file, contains active SVG content, or collides at publication | `content_asset` → HTML |
| `EROUTEMISSING` | error | Published local `href`/`src` resolves to no output this build intends to keep | `link_audit` → HTML commit |
| `EROUTEESCAPE` | error | Published local `href`/`src` climbs above the output root and can never be served | `link_audit` → HTML commit |
| `EFRAGMENTMISSING` | reserved | Published local reference resolves, but its `#fragment` is not an id on the target page. Not yet emitted; see [documentation-links.md](documentation-links.md) | — |
| `EUSAGE` | error | CLI usage / flag error (unknown flag, conflicts, malformed options) | CLI (exit 2; not in build-report) |
| `EIO` | error | I/O or system failure (missing content root, unreadable file, unexpected runtime) | pipeline / CLI (exit 3 when pure I/O) |

### `EPARENTNOTTRUNK` compatibility disposition

`EPARENTNOTTRUNK` is retained in the closed diagnostic-code enum and name table
as a retired compatibility value for consumers that still recognize the
historical one-hop contract. The current validator never emits it. A Satellite
may name either a Trunk or another Satellite as its immediate parent; no
diagnostic is produced merely because the parent is non-root. Current invalid
parent topology remains covered by `EPARENTMISSING`, `EPARENTSELF`, and
`EPARENTCYCLE`.

On the HTML path, component tokenizer failures are emitted as structured
`ECOMPONENT` diagnostics with the content-relative source path and the
full-source line/column of the offending tag; the CLI does not replace them
with a bare internal `ComponentFailed` error.

HTML parser failures follow the same rule: when a defensive HTML-path parse
check encounters invalid frontmatter, UTF-8, or a path, it preserves the
parser category, source path, and line/column in the emitted diagnostic before
returning the stable `ParseFailed` control error.

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

Unknown codes must not be invented by the v0.2 compiler without a contract
amendment. Implementations may later **subdivide** messages under the same
category but must keep the `code` string stable.

---

## Source locations

| Issue | Location points to |
|-------|---------------------|
| Duplicate id | First line of the later file in `sourcePath` order (report both paths in `message`) |
| Unclosed frontmatter | Line of opening `---` (1:1) or EOF line |
| Unknown / bad key | Start of that field line |
| Missing parent | Page source (line/column from validation; v0.2 often `1:1`) |
| Cycle | Each involved file (`1:1` in v0.2) with full cycle path in message |
| Encoding | `1:1` of the file |
| Invalid path/id | The offending path or the `id:` field line |

If a precise column is unknown, use column `1`.

---

## Exit codes

| Code | Meaning |
|-----:|---------|
| `0` | Success: selected operation passed with zero `error` diagnostics; requested artifacts are complete, or no artifacts were requested by `validate` |
| `1` | Content / validation failed: one or more content `error` diagnostics |
| `2` | Usage / CLI error (`EUSAGE`) |
| `3` | I/O or system failure (`EIO`) |

Rules:

1. An artifact-producing path exits `0` only when its contracted output is
   complete. `validate` exits `0` only when every applicable prepublication
   phase passed and still writes no artifact.
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
   unchanged when those artifacts were selected; validation remains
   artifact-free.

---

## stderr / stdout

| Stream | Content |
|--------|---------|
| **stderr** | Diagnostics (text form); optional progress logs (`boris: load/roll/ignite/reset`) |
| **stdout** | Reserved; v0.2 prints nothing on the success path (progress uses stderr via `std.debug`) |

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
| `EPARENTNOTTRUNK` | retired compatibility code; current validator never emits it |
| `EPARENTCYCLE` | `cycle`, contract `cycles` / `longer-cycle` |
| `EFRONTMATTER` | `duplicate-key`, `unclosed-frontmatter`, `nested-mapping` |
| `EINVALIDUTF8` | `invalid-utf8` |
| `EUNICODE` | `fixtures/hostile-output/unicode-smuggling` (rejects) and `fixtures/hostile-output/legitimate-punctuation` (must not reject) |
| `EINVALIDPATH` | `invalid-path-id`, contract `invalid-id`, contract `case-id-collision` |

`EUSAGE` and `EIO` are CLI/runtime categories; content-tree fixtures do not
cover them except missing content root (`EIO`).

---

## Non-goals

- Language server protocol
- JSON-RPC
