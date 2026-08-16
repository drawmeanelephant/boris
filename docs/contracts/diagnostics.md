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

The route/location audit is shared between `build` and `validate` (which runs
it in memory over the assembled page bytes — see
[`validation.md`](validation.md)), so `EROUTEMISSING`, `EROUTEESCAPE`, and
`EPUBLICATIONLOCATION` fail both compilation and validation with identical
diagnostics.

The Pages publication slice adds `EPUBLICATIONLOCATION` for the pre-commit
semantic URL/location gate. It is emitted when a root-relative project-site
route omits the declared base path, or when a Boris-owned canonical/public URL
uses a different origin or base path. This is a publication failure, not a
warning; it does not add a fourth publication-evidence check.

The Cooklang input slice adds `ECOOKLANG` for the `.cook` input family. It is
emitted when a page tree mixes `.cook` with another page extension or selects
the wrong input mode, and for the seam's refusals: a timer with neither name
nor duration, an unnamed section, an invalid recipe reference, or a control
character. Malformed structure (an unterminated `{`, `(` or `[-`, or an
unclosed body-only frontmatter fence) is **not** an error: Oliver degrades it
to literal text and the same code is emitted as a warning with Oliver's stable
code in the message. Macros, wiki links and raw HTML written as author text are
escaped, not refused.
See [cooklang-compatibility.md](cooklang-compatibility.md).

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
| `ECOOKLANG` | error / warning | Input-family mismatch, refused Cooklang construct (empty timer or section, invalid recipe reference, control character), or — as a warning — malformed structure Oliver degraded to literal text | scanner / `cooklang_seam.toMarkdown` → pipeline / HTML |
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
| `EROUTEMISSING` | error | Published local `href`/`src` resolves to no output this build intends to keep | `link_audit` → HTML commit / validate |
| `EROUTEESCAPE` | error | Published local `href`/`src` climbs above the output root and can never be served | `link_audit` → HTML commit / validate |
| `EPUBLICATIONLOCATION` | error | A Boris-owned rendered public URL disagrees with the declared publication origin/base path, or a project-site root-relative route omits that base path | `link_audit` → HTML pre-commit gate / validate |
| `EFRAGMENTMISSING` | reserved | Published local reference resolves, but its `#fragment` is not an id on the target page. Not yet emitted; see [documentation-links.md](documentation-links.md) | — |
| `ELAYOUTMISSINGMARKER` | error | Layout template lacks a required/declared slot marker, or names an unknown marker | `assemble.loadLayout` → HTML load/validate |
| `ELAYOUTDUPLICATEMARKER` | error | Layout template repeats a slot marker | `assemble.loadLayout` → HTML load/validate |
| `ELAYOUTPATH` | error | Layout path is illegal (absolute, `..`, backslash, or otherwise non-relative) | `layout_select.validateLayoutPath` → HTML load/validate |
| `ELAYOUTASSET` | error | Layout template references an invalid or excessive asset url | `assemble.loadLayout` / `theme.requireReferencedAssets` → HTML load/validate |
| `ELAYOUTRULE` | error | Layout-rule selection failure (ambiguous glob, duplicate/invalid selector, mixed theme roots, or rule bounds) | `layout_select` → HTML load/validate |
| `ELAYOUT` | error | Generic layout failure (structural bounds, invalid UTF-8, …) | HTML load/validate fallback |
| `EVERIFICATIONHEAD` | warning | Standard.site verification is configured but a selected layout omits the compiler-owned `{{head}}` slot, so eligible pages cannot emit their document AT-URI links; the verification report records them as `not_verified` | `compile.compilePagesInner` → HTML publish / validate |
| `EUSAGE` | error | CLI usage / flag error (unknown flag, conflicts, malformed options) | CLI (exit 2; not in build-report) |
| `EIO` | error | I/O or system failure (missing content root, unreadable file, unexpected runtime) | pipeline / CLI (exit 3 when pure I/O) |

## HTML-path machine-readable report

`build` and `validate` accept `--report PATH` and write a deterministic JSON
report to `PATH` on **both** success and failure (the file is written even when
the command exits 1). This is the machine-readable twin of the HTML-path
stderr text, covering every HTML-path diagnostic class: parse/graph,
component, include, wiki-link, asset, link-audit (`EROUTEMISSING`,
`EROUTEESCAPE`, `EPUBLICATIONLOCATION`), and layout/theme. It is the surface
the preview server ([#392]'s `serve` loop) and the Boris editor expose; the IR
path keeps its own auto-written `build-report.json`.

- Schema: `html-build-report-0.1.0` — see
  [schemas/html-build-report-0.1.0.schema.json](schemas/html-build-report-0.1.0.schema.json).
- Top-level shape matches the IR report: `schemaVersion`, `compilerId`, `ok`,
  `contentRoot`, `outDir`, `errorCount`, `diagnostics`. There is no
  `pageCount` (the HTML path does not expose a single page count across
  targets).
- Each diagnostic object uses the **exact key order** of the IR diagnostic
  object: `severity, code, message, remediation, sourcePath, line, column, id`.
- Diagnostics are sorted with the same deterministic comparator as the IR
  report (source path, line, column, code, message).
- `--report` is additive: stderr text, exit codes, and emitted artifact bytes
  are unchanged with or without it. `validate --report` writes the same shape
  (its `outDir` reflects the configured HTML output directory even though
  validation publishes nothing).
- `--report` is rejected on `watch` and on non-HTML build modes (IR/RAG/etc.);
  `check`/`impact` keep their own `--report` analysis surface.

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
| `4` | Authorization denied: the one-shot Standard.site publish grant was denied in the browser (`standard-site publish`) |
| `5` | Timeout: the Standard.site publish callback, browser, or network deadline expired |
| `6` | Compatibility: the Standard.site publish localhost client or grant was rejected by the authorization server |
| `7` | Partial publication: `standard-site publish` landed some records but some failed; the evidence records exactly what happened |
| `8` | Verification: `standard-site publish` failed a binding or plan check (plan drift, digest, DID, PDS, collection, rkey, callback identity) with zero writes, or `standard-site verify` found a missing/mismatched emitted surface (head link or well-known file) |
| `9` | Session: `standard-site publish`/`login`/`sessions`/`logout` failed at the persistent-session layer — no stored session, revoked or ambiguous refresh, an authority change, or a corrupt/locked/unusable store |

Exit codes `4`–`9` belong exclusively to the explicit `standard-site` family
(`publish`, `login`, `sessions`, `logout`, `smoke`, `verify`);
build/validate/watch/plan/init never emit any of them. On `7`, the publish
evidence or the smoke result artifact is still written (stdout or `--out`) so
the operator can see exactly which records landed or were left behind; on `9`
nothing was published and the operator re-authorizes with
`standard-site login` (see [`atproto-sessions.md`](atproto-sessions.md)). The
`smoke` command reuses these codes for its phases: `7` marks a partial write
or a cleanup failure, `8` marks a namespace collision or a readback/surface
mismatch (see [`atproto-live-smoke.md`](atproto-live-smoke.md)). The offline
`standard-site verify` command emits `8` when any emitted head link or the
well-known file (or its base-path sideband) does not match the freshly
rendered projection, with zero writes and zero network.

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
