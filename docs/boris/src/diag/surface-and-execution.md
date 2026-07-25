---
title: "`src/diag.zig` surface and execution"
id: docs/boris/src/diag/surface-and-execution
parent: docs/boris/src/diag
status: draft
tags: [boris, zig, source-reference, surface, diag]
---

# `src/diag.zig` surface and execution

## Data model

### `Severity`

```
pub const Severity = enum {
    error_,
    warning,
    info,
    ...
};
```

Three variants. The variant `error_` uses a trailing underscore to avoid collision with Zig's reserved `error` keyword; both `jsonName()` and `textName()` map it to the string `"error"`. `textName()` is a thin alias for `jsonName()` — the two currently produce identical output, making them interchangeable. The file does not document whether this equivalence is a contract or an implementation convenience.


| Variant | `jsonName()` / `textName()` |
| :-- | :-- |
| `error_` | `"error"` |
| `warning` | `"warning"` |
| `info` | `"info"` |

The contract in `docs/contracts/diagnostics.md` states that severity affects exit codes: `error` forces non-zero exit; `warning` and `info` do not. That behavior is implemented in `pipeline.zig` (via `countErrors`), not here.

### `Code`

A closed enum of 21 variants. The `name()` method uses `@tagName(self)`, which returns the Zig source identifier string at compile time. Because the variant names are chosen to be identical to the normative contract strings (e.g. `EDUPLICATEID`, not `E_DUPLICATE_ID`), `@tagName` produces the correct output without any switch or lookup table.

**All declared codes:**


| Variant | Contract string | Category |
| :-- | :-- | :-- |
| `EDUPLICATEID` | `EDUPLICATEID` | Graph: two pages share an id |
| `EPARENTMISSING` | `EPARENTMISSING` | Graph: parent id not in page set |
| `EPARENTSELF` | `EPARENTSELF` | Graph: page is its own parent |
| `EPARENTNOTTRUNK` | `EPARENTNOTTRUNK` | Graph: satellite-of-satellite |
| `EPARENTCYCLE` | `EPARENTCYCLE` | Graph: cycle in parent edges |
| `EFRONTMATTER` | `EFRONTMATTER` | Parser: malformed frontmatter |
| `EINVALIDUTF8` | `EINVALIDUTF8` | Parser: non-UTF-8 or BOM |
| `EINVALIDPATH` | `EINVALIDPATH` | Scanner/parser/graph: illegal path or id |
| `ETEXTILE` | `ETEXTILE` | Textile adapter failure |
| `ECOMPONENT` | `ECOMPONENT` | Aside/component tokenizer failure |
| `EINCLUDESYNTAX` | `EINCLUDESYNTAX` | Malformed `&#123;&#123;include …&#125;&#125;` |
| `EINCLUDEMISSING` | `EINCLUDEMISSING` | Include target not found |
| `EINCLUDECYCLE` | `EINCLUDECYCLE` | Transclusion cycle |
| `EREFERENCESYNTAX` | `EREFERENCESYNTAX` | Malformed `&#91;&#91;…&#93;&#93;` wikilink |
| `EREFERENCEMISSING` | `EREFERENCEMISSING` | Wikilink target not in graph |
| `ERELATIONMISSING` | `ERELATIONMISSING` | Semantic relation target not in graph |
| `ERELATIONSELF` | `ERELATIONSELF` | Relation targets its source page |
| `ERELATIONDUPLICATE` | `ERELATIONDUPLICATE` | Repeated semantic relation tuple |
| `EASSET` | `EASSET` | Content-local asset path/collision failure |
| `EUSAGE` | `EUSAGE` | CLI usage / flag error |
| `EIO` | `EIO` | I/O or system failure |

The `@tagName` mechanism provides a structural guarantee that the string emitted equals the declared variant name. Any rename of a variant that does not simultaneously update the contract would produce a mismatch detectable by the name test — but only for the 17 variants covered by that test.

### `Diagnostic`

```
pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    message: []const u8,
    remediation: []const u8 = "",
    source_path: []const u8 = "",
    line: ?u32 = null,
    column: ?u32 = null,
    id: []const u8 = "",

    pub fn isError(self: Diagnostic) bool { ... }
};
```

A plain value struct. All slice fields (`message`, `remediation`, `source_path`, `id`) are caller-owned; the module-level doc comment states these are owned by the caller's retain allocator (typically the long-lived arena for a compile run). `Diagnostic` itself performs no allocation and holds no allocator reference.

**Field notes:**

- `line` and `column` are `?u32`, consistent with the contract's nullable integer fields. The contract specifies both as 1-based; `diag.zig` does not enforce this — it is a caller contract.
- `source_path` defaults to `""` (empty string), which the contract treats as "not applicable." The sort comparator treats empty strings as sorting before non-empty strings (standard lexicographic behavior on byte sequences), which is consistent with the contract's note that path-empty entries sort first in practice.
- `remediation` defaults to `""`. The contract requires this field to be present even when empty.
- `id` defaults to `""` and maps to the contract's `id` field (entity id when known).
- The JSON field name in the contract is `sourcePath` (camelCase), while the Zig field is `source_path` (snake\_case). The JSON serialization of `Diagnostic` to `build-report.json` is performed by callers (pipeline.zig / a json\_out helper), not by this file. The field name mapping is a caller responsibility.

`isError()` returns `true` iff `self.severity == .error_`. It is used by `countErrors`.

***

## Free functions

### `lessThan`

```
pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool
```

A five-key sort comparator compatible with `std.mem.sort`. Sort keys in order:

1. `source_path` — lexicographic ascending; empty string sorts before any non-empty path.
2. `line` — numeric ascending; `null` maps to `std.math.maxInt(u32)` (sorts last).
3. `column` — numeric ascending; `null` maps to `std.math.maxInt(u32)` (sorts last).
4. `code.name()` — lexicographic ascending on the code string.
5. `message` — lexicographic ascending.

The `null`-as-maxInt mapping for line and column is structurally present in the code and matches the contract's intent that located diagnostics (with line/column) sort before unlocated ones within a given file. However, the edge case where `null` maps to the same integer as a legitimate `u32::MAX` line or column number is technically present — this is astronomically unlikely for real content files but is not defended against.

### `sortDiagnostics`

```
pub fn sortDiagnostics(diags: []Diagnostic) void
```

Calls `std.mem.sort` with `lessThan`. Sorts in-place; no allocation. The sort is not guaranteed stable by `std.mem.sort` (which uses a non-stable algorithm in Zig's standard library). Two diagnostics that are equal across all five sort keys may appear in either order after sorting. Whether any consumer requires a fully stable sort for equal diagnostics is not determined from this file alone.

### `formatText`

```
pub fn formatText(d: Diagnostic, allocator: std.mem.Allocator) ![]u8
```

Allocates and returns a caller-owned byte slice containing the text representation of one diagnostic. The caller must free the result.

Three branches match the contract's three text forms:

**No source path** (`d.source_path.len == 0`):

```
{severity}: {code}: {message}[ [{remediation}]]
```

**Source path with line** (`d.line != null`):

```
{severity}: {code}: {source_path}:{line}:{column}: {message}[ [{remediation}]]
```

Column defaults to `1` when `d.column == null`, matching the contract's "use column 1 if unknown" rule.

**Source path without line** (fallthrough):

```
{severity}: {code}: {source_path}: {message}[ [{remediation}]]
```

Remediation is appended as ` [{remediation}]` only when `d.remediation.len > 0`. The remediation string is formatted with `allocPrint` and then freed with `defer` before the final allocation — this is a potential double-free hazard if the allocator is an arena (arena `free` is a no-op, so harmless in that case, but technically the lifetime is managed correctly only because the defer frees before the outer allocPrint). In practice, callers use arenas or `std.testing.allocator`, where this pattern is safe.

**No JSON escaping:** `formatText` emits the message, remediation, path, and id fields as raw bytes without any escaping. This is appropriate for stderr text output but confirms that callers must not use `formatText` output as a JSON string value.

### `countErrors`

```
pub fn countErrors(diags: []const Diagnostic) usize
```

Linear scan over a slice, counting entries where `isError()` is true. No allocation. Returns a `usize`. Used by pipeline.zig to determine exit code.

***

## Contract alignment and discrepancies

### Confirmed aligned

- All 21 variant names in `Code` match the normative contract table in `docs/contracts/diagnostics.md` (confirmed by inspection).
- Sort key order (path, line, column, code, message) matches the contract exactly.
- `null` line/column mapped to sort-last via maxInt matches the contract's intent.
- Three `formatText` branches match the three text forms specified in the contract.
- Column defaults to `1` when null in the line-present branch, matching the contract's location guidance.
- `Severity.jsonName()` returns lowercase strings matching the contract's severity values.


### Potentially misaligned or uncertain

- The contract JSON field is `sourcePath` (camelCase); the Zig field is `source_path` (snake\_case). JSON serialization must perform this translation. This file does not perform JSON serialization, so the mapping is a caller responsibility — but it is a latent discrepancy that could produce incorrect JSON if any caller serializes field names automatically from struct field names.
- The contract specifies that `sourcePath` should be `null` in JSON when not applicable, while `Diagnostic.source_path` defaults to `""` (empty string). A caller that serializes `""` as `""` rather than `null` would violate the contract's JSON schema. This file does not serialize JSON, so the gap is a caller responsibility.
- `textName()` is a pure alias for `jsonName()`. If the contract were ever amended to use different severity strings in text versus JSON, this alias would need to be broken. No such divergence currently exists.

***
