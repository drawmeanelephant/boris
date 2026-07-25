---
title: "`src/textile.zig` evidence and cases"
id: docs/boris/src/textile/evidence-and-cases
parent: docs/boris/src/textile
status: draft
tags: [boris, zig, source-reference, evidence, textile]
---

# `src/textile.zig` evidence and cases

## Internal structure walkthrough

The module is organized as a set of pure functions that together form a recursive-descent block parser. No mutable global state exists.

### Line reader

`readLine(body, start)` returns a `PhysicalLine` struct containing the stripped text (CR removed if present before LF), the next cursor position, and a `had_newline` flag. This is the only function that touches raw input bytes in an unbounded scan; its loop condition `body[end] != '\n'` is safe because the outer loop guard prevents `start >= body.len`.

CRLF handling: the function strips a trailing `\r` from `text` only if the line ends with `\r\n`. A lone `\r` at the end of a line (no following `\n`) is **not** stripped and would be passed through to `convertInline`, where it would be rejected as a control character (byte value `0x0D < 0x20`). This is structurally checked behavior, not explicitly tested.

### Block dispatch (`toMarkdown` → `convertBlock`)

`toMarkdown` iterates the body, skipping blank lines (preserving one `\n` per blank line in output) and dispatching contiguous non-blank line groups as blocks. The list-adjacency check — detecting when an unordered and an ordered list block appear without an intervening paragraph — is the only structural check that bypasses `convertBlock` entirely and emits a `Result` with an inline diagnostic directly from `toMarkdown`.

`convertBlock` classifies the first line of a block:

- `h1.`–`h6. `: heading
- `p. `: explicit paragraph
- `bq. `: block quote
- `* ` or `# `: list
- Anything matched by `unsupportedBlockMessage`: immediate rejection
- Empty `p.`, `bq.`, `*`, `#` tokens: immediate rejection
- Anything else: implicit paragraph (no prefix consumed)

The function does **not** implement a general-purpose block parser with lookahead; it is a linear single-pass classification.

### Inline converter (`convertInline`)

`convertInline` is the most complex function. It iterates a single physical line character by character, handling:

1. **Control character rejection** (`c < 0x20 and c != '\t'`)
2. **Boris macro / wiki-link injection detection** (`&#123;&#123;` and `&#91;&#91;` openers)
3. **Raw HTML detection** (via `looksLikeRawHtml`)
4. **Textile footnote references** (`[digit+]`)
5. **Unsupported double-delimiter phrases** (`**`, `__`, `??`, `==`)
6. **Unsupported single-delimiter phrases with balanced closers** (`%`, `^`, `~`, `!`)
7. **Link conversion** (`"label":destination`)
8. **Supported phrase modifiers** (`*`, `_`, `-`, `+`, `@`) with opener/closer detection
9. **Ordered-list escape** (a line consisting entirely of digits followed by `. `)
10. **Fallthrough character escaping** via `appendMarkdownByte`

The opener/closer detection (`openerAt`, `closingAt`, `findClosing`) is context-sensitive: an opener must be preceded by whitespace or opening punctuation (or be at position 0), and a closer must be followed by whitespace, closing punctuation, or end-of-line. An opener without a closer is a hard error (`error.InvalidTextile`), not a silent pass-through. This is a critical correctness property for preventing unescaped Textile syntax from appearing in the output.

### Escaping

`appendMarkdownByte` escapes the following characters with a backslash: `\`, `````, `*`, `_`, `{`, `}`, `[`, `]`, `#`, `+`, `-`, `!`, `|`, `~`. It encodes `&` as `&amp;`, `<` as `&lt;`, `>` as `&gt;`. Note: `-` is in the backslash-escape set (to prevent accidental Markdown list or HR markers in prose), but inside a phrase modifier span `-` is used as the Textile strikethrough delimiter and is handled by the phrase-modifier branch before `appendMarkdownByte` is reached.

`appendHtmlText` is used for `<ins>` content only and escapes a narrower set appropriate for HTML attribute/content context: `&`, `<`, `>`, and the characters `````, `*`, `_`, `[`, `]` that Markdown might reinterpret if they escaped the `<ins>…</ins>` wrapper in a Markdown-aware renderer.

### Link validation (`validDestination`)

`validDestination` rejects: empty strings; strings containing whitespace (`<= 0x20`), DEL (`0x7f`), backslash, quotes, angle brackets, literal parentheses, or backtick. It additionally requires scheme-specific minimum lengths and rejects protocol-relative `//` URLs. The exhaustive rejection of `javascript:` (and any unrecognized scheme that does not match one of the allowlisted prefixes) is structurally enforced: only `http://`, `https://`, `mailto:`, `/`, `./`, `../`, and `#` pass. This is structurally checked; the test exercises `javascript:alert` specifically.

***

## Test inventory

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `readTestFile` | Helper fn | Reads a file from the repo by path using `std.Io` | A relative path from the repo root, plus allocator | Returns `[]u8` caller must free; errors on missing file | File I/O for fixture loading |
| `expectFixture` | Helper fn | Loads a source `.textile` file, parses it via `parser.zig`, calls `toMarkdown` on the body, and compares output bytes to a golden `.md` file | Two relative paths (source + expected) | Both parse and convert succeed; output equals golden file byte-for-byte | Full adapter round-trip including parser integration |
| `Textile compatibility fixtures match adapted Markdown goldens` | Test | Validates two specific fixtures: `content/index.textile` → `expected/adapted/index.md` and `content/guides/intro.textile` → `expected/adapted/guides/intro.md` | Files under `docs/contracts/fixtures/textile-compatibility/` | `expectEqualStrings` passes for each pair | Block dispatch, inline conversion, escaping, link transformation — all exercised by fixture content |
| `Textile adapter rejects attributes malformed modifiers macros and unsafe links` | Test | Runs 14 adversarial or unsupported bodies through `toMarkdown` and checks diagnostic keyword | 14 inline body strings listed in a comptime array; `std.testing.allocator` | Each `result.isOk()` is false; `result.diagnostic.?.message` contains the expected needle substring | Rejection surface coverage — see per-case analysis below |
| `Textile table declarations fail at the declaration line` | Test | Confirms that a `table.` declaration reports line 1, column 1 | `"table.\n| Header |\n"` | `!result.isOk()`, `line == 1`, `column == 1` | Diagnostic location accuracy for block-level rejection |
| `Textile adapter escapes literal Markdown and HTML without changing ordinary prose` | Test | Verifies that `#`, `[`, `]`, `<`, `>`, `&` in plain prose are escaped without corrupting the prose content | `"Plain # hash, [brackets], 5 < 7 & 8 > 3.\n"` | Output equals `"Plain \\# hash, \\[brackets\\], 5 &lt; 7 &amp; 8 &gt; 3.\n"` | `appendMarkdownByte` correctness |
| `Textile adapter is deterministic` | Test | Calls `toMarkdown` twice on the same body and compares outputs | A mixed body with heading, inline modifiers, and a link | Both calls return `isOk()` and `expectEqualStrings` passes | Absence of observable state mutation between calls |


***

## Rejection case analysis

### `h2{color:red}. Styled\n` — attributes/CSS

**Input:** A heading line with a CSS attribute block in `{…}` between the `h2` and the `.`.

**Which boundary:** `headingLevel` returns `null` (the `.` is at index 3, but `line[^1_2]` is `{` not `.`). The line falls through to `unsupportedBlockMessage`, which calls `looksLikeHeadingSignature`. That function returns true because `line[^1_2]` is in `".({[<>="`. The returned message contains `"attributes/CSS"`.

**Expected response:** `Result` with diagnostic; message substring `"attributes/CSS"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Heading-attribute forms with `(`, `[`, `<`, `>`, `=` modifiers are not individually tested; only `{` is exercised.

***

### `A *strong phrase without a closer.\n` — unclosed phrase modifier

**Input:** `*` opener in an inline phrase context with no closing `*`.

**Which boundary:** `convertInline` detects `openerAt(text, i, '*')` → true, calls `findClosing` → `null`, returns `reject(…, "unclosed Textile phrase modifier")`.

**Expected response:** `Result` with diagnostic; message contains `"unclosed"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Other delimiters (`_`, `-`, `+`, `@`) with unclosed forms are not individually tested; only `*` is exercised.

***

### `| A | table |\n` — pipe-table line

**Input:** A line beginning with `|`.

**Which boundary:** `unsupportedBlockMessage` returns `"Textile tables are unsupported"` for lines where `line[^1_0] == '|'`.

**Expected response:** `Result` with diagnostic; message contains `"tables"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Multi-line pipe tables, tables with leading spaces, and tables after `table.` declarations each have distinct code paths; only the plain `|`-leading form is tested in this case (the `table.` form is tested separately).

***

### `table.\n| A | table |\n`, `table(class).\n`, `table{width:100%}.\n` — table declarations

**Input:** Lines beginning with `table` followed by `.`, `(`, or `{`.

**Which boundary:** `unsupportedBlockMessage` → `looksLikeTableDeclaration` → matches on the character at `line["table".len]`. Returns `"Textile tables and table modifiers are unsupported"`.

**Expected response:** `Result` with diagnostic; message contains `"tables and table modifiers"`.

**Evidence strength:** Directly demonstrated for all three declaration forms.

**Residual gap:** `table[`, `table<`, `table>`, `table=` variants are structurally checked (all listed in the `switch` in `looksLikeTableDeclaration`) but not directly exercised in the rejection table.

***

### `fn1. Note\n` — footnote block

**Input:** A line beginning with `fn` followed by a digit followed by `.`.

**Which boundary:** `unsupportedBlockMessage` → `looksLikeFootnoteBlock` → matches.

**Expected response:** `Result` with diagnostic; message contains `"footnotes"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Multi-digit footnote numbers, footnotes with `*` marker, inline footnote references (`[^1_1]`) are not individually tested.

***

### `&#123;&#123;include includes/a.md&#125;&#125;\n` — macro injection (block level)

**Input:** A line that would parse as an implicit paragraph with `&#123;&#123;` at the start.

**Which boundary:** `convertInline` detects `c == '{' and text[i+1] == '{'` before any phrase-modifier logic and calls `reject(…, "Boris macros, wiki links, and components are unsupported in Textile mode")`.

**Expected response:** `Result` with diagnostic; message contains `"macros"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** `&#91;&#91;` wiki-link injection at block level is structurally checked by the same branch but not separately tested in this case table.

***

### `A @&#123;&#123;include includes/a.md&#125;&#125;@ phrase.\n` — macro injection inside code span

**Input:** An `@…@` code span containing a `&#123;&#123;` sequence.

**Which boundary:** `convertInline` enters the `@` phrase-modifier branch, reaches `std.mem.indexOf(u8, inner, "&#123;&#123;") != null`, calls `reject(…, "Boris macros and wiki links are unsupported inside Textile phrases")`.

**Expected response:** `Result` with diagnostic; message contains `"macros"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Macro injection inside `*`, `_`, `-`, `+` phrases is structurally checked by the same `indexOf` guard but not directly exercised.

***

### `A @&lt;Aside>@ phrase.\n` — component tag inside code span

**Input:** An `@…@` code span containing `&lt;Aside>` raw HTML.

**Which boundary:** `convertInline` enters `@` phrase-modifier branch, reaches `containsRawHtml(inner)` → `looksLikeRawHtml` returns true for `&lt;A…`; calls `reject(…, "raw HTML and executable components are unsupported inside Textile phrases")`.

**Expected response:** `Result` with diagnostic; message contains `"components"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Raw HTML tags inside `*`, `_`, `-`, `+` phrases follow the same `containsRawHtml` guard; only `@` is exercised.

***

### `&lt;Aside kind="tip">x&lt;/Aside&gt;\n` — block-level raw HTML

**Input:** A line beginning with `&lt;A` (an opening HTML tag).

**Which boundary:** `convertInline` reaches `c == '<' and looksLikeRawHtml(text, i)` before any phrase-modifier logic; calls `reject(…, "raw HTML and executable components are unsupported in Textile mode")`.

**Expected response:** `Result` with diagnostic; message contains `"components"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** `<?`, `<!`, `</` forms are structurally checked by `looksLikeRawHtml` (`next == '/' or '!' or '?'`) but not directly exercised.

***

### `"bad":javascript:alert\n` — unsafe link destination

**Input:** A Textile link with a `javascript:` destination.

**Which boundary:** `convertLink` extracts the destination string `javascript:alert`, calls `validDestination`. The function checks each allowlisted prefix; `javascript:` matches none of them, returns `false`. `convertLink` calls `reject(…, "Textile link destination is missing or unsafe")`.

**Expected response:** `Result` with diagnostic; message contains `"unsafe"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** Other unsafe schemes (`data:`, `vbscript:`, protocol-relative `//`) are not directly exercised; they pass through `validDestination`'s exhaustive prefix allowlist and would be rejected, but this is contract-only for those specific inputs.

***

### `** nested\n` — nested list marker

**Input:** A line beginning with `** ` (double asterisk plus space).

**Which boundary:** `unsupportedBlockMessage` matches `std.mem.startsWith(u8, line, "** ")`, returns `"nested and mixed Textile lists are unsupported"`.

**Expected response:** `Result` with diagnostic; message contains `"nested"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** `## `, `*# `, `#* ` forms are structurally checked by the same `startsWith` branches; only `**` is exercised.

***

### `* bullet\n\n# number\n` — adjacent list type transition

**Input:** An unordered list block followed by an ordered list block with only a blank line between them.

**Which boundary:** In `toMarkdown`, after processing the `*` block, `previous_list` is set to `false`. When the `# ` block is detected, `current_list = true`, and `previous_list != current_list` triggers an inline `Result` return with message `"adjacent unordered and ordered Textile list blocks require an intervening paragraph"`.

**Expected response:** `Result` with diagnostic; message contains `"adjacent"`.

**Evidence strength:** Directly demonstrated.

**Residual gap:** The reverse transition (ordered → unordered) is structurally identical but not directly exercised. Two consecutive same-type list blocks (allowed by the contract) are not explicitly tested.

***

## Control flow

```text
zig build test
    → run_textile_tests (cwd = repo root)
        → test "Textile compatibility fixtures match adapted Markdown goldens"
            → readTestFile("docs/contracts/fixtures/textile-compatibility/content/...")
            → parser.parse(source)  ← src/parser.zig
            → toMarkdown(parsed.doc.body, gpa)
                → utf8ValidateSlice(body)
                → per-block loop:
                    → readLine(body, cursor)
                    → isBlank check → preserve newline or dispatch
                    → list-adjacency check in toMarkdown
                    → convertBlock(out, allocator, body, block_start, block_end, ...)
                        → headingLevel / p. / bq. / * / # / unsupportedBlockMessage
                        → convertParagraph / convertQuote / convertList
                            → convertInline(out, allocator, text, ...)
                                → control char / macro / HTML / footnote checks
                                → phrase opener detection (openerAt)
                                → convertLink or phrase modifier handler
                                → appendMarkdownByte (fallthrough)
            → expectEqualStrings(expected, result.markdown)

        → test "Textile adapter rejects ..."
            → toMarkdown(case.body, std.testing.allocator)  [×14]
            → expect(!result.isOk())
            → expect(indexOf(result.diagnostic.?.message, needle) != null)

        → test "Textile table declarations fail at the declaration line"
            → toMarkdown("table.\n| Header |\n", ...)
            → expect(!result.isOk())
            → expectEqual(1, line); expectEqual(1, column)

        → test "Textile adapter escapes literal Markdown ..."
            → toMarkdown("Plain # hash, ...", ...)
            → expectEqualStrings(expected_escaped, result.markdown)

        → test "Textile adapter is deterministic"
            → toMarkdown(body, ...) × 2
            → expectEqualStrings(a.markdown, b.markdown)
```


***
