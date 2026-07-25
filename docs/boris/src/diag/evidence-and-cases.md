---
title: "`src/diag.zig` evidence and cases"
id: docs/boris/src/diag/evidence-and-cases
parent: docs/boris/src/diag
status: draft
tags: [boris, zig, source-reference, evidence, diag]
---

# `src/diag.zig` evidence and cases

## Embedded tests

### `test "sortDiagnostics orders by path then line"`

**Setup:** Three `Diagnostic` values sharing code `EDUPLICATEID` and severity `error_`, with paths `"b.md"` / `"a.md"` / `"a.md"` and lines `1` / `2` / `1`. The initial order is b/a2/a1 (deliberately unsorted).

**Assertions after `sortDiagnostics`:**

1. `diags[0].source_path == "a.md"` and `diags[0].line == 1` — path sort before line sort.
2. `diags[1].source_path == "a.md"` and `diags[1].line == 2` — same path, higher line sorts later.
3. `diags[2].source_path == "b.md"` — path `"b"` sorts after `"a"` regardless of line.

**What this directly demonstrates:** Primary sort by `source_path` and secondary sort by `line` work correctly for a three-element fixture.

**What this does not demonstrate:**

- Tertiary sort by `column`.
- Quaternary sort by `code.name()`.
- Quinary sort by `message`.
- Sort behavior when `line == null` (null-as-maxInt mapping).
- Sort behavior when `source_path == ""` (empty string ordering).
- Stability of equal elements.


### `test "Code names match contract strings"`

**Setup:** Calls `.name()` on 17 of the 21 `Code` variants and compares each result to the expected string literal using `expectEqualStrings`.

**Assertions:** 17 direct string equality checks, one per variant tested.

**What this directly demonstrates:** The `@tagName` mechanism produces the exact normative contract string for 17 of the 21 codes. Because `@tagName` is a compile-time identity mapping, passing this test is structurally equivalent to demonstrating that the variant names are spelled identically to the contract strings.

**What this does not demonstrate:**

- The four codes not exercised: `ERELATIONMISSING`, `ERELATIONSELF`, `ERELATIONDUPLICATE`, `EASSET`. These were added later (semantic relations and asset handling, per the contract document's history) and are absent from the name test. Their `@tagName` output is correct by the same mechanism, but the test does not formally confirm them.
- That the complete set of codes in `diag.zig` matches the complete set in `docs/contracts/diagnostics.md` — a code added to one but not the other would not be caught by this test.

***
