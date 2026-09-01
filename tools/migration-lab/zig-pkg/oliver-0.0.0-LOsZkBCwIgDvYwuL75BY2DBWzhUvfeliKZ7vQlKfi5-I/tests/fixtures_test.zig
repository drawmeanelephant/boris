//! Fixture-driven tests.
//!
//! Convention (see docs/TESTS.md): for each fixture `<name>` there is an
//! input file `tests/fixtures/<dialect>/<name>.<ext>` (`.md` for markdown,
//! `.textile` for textile) and an expected-output file
//! `tests/fixtures/<dialect>/<name>.html`. Expected outputs are exact bytes:
//! trailing newlines matter. Fixtures are embedded at comptime so tests run
//! anywhere without filesystem access; the list below is the index.
//!
//! Markdown and Textile fixtures live in separate directories even when they
//! describe the same normalized structure.

const std = @import("std");
const oliver = @import("oliver");

const MarkdownFixture = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

const markdown_fixtures = [_]MarkdownFixture{
    .{
        .name = "paragraph",
        .input = @embedFile("fixtures/markdown/paragraph.md"),
        .expected = @embedFile("fixtures/markdown/paragraph.html"),
    },
    .{
        .name = "two-paragraphs",
        .input = @embedFile("fixtures/markdown/two-paragraphs.md"),
        .expected = @embedFile("fixtures/markdown/two-paragraphs.html"),
    },
    .{
        .name = "paragraph-soft-break",
        .input = @embedFile("fixtures/markdown/paragraph-soft-break.md"),
        .expected = @embedFile("fixtures/markdown/paragraph-soft-break.html"),
    },
    .{
        .name = "blank-lines",
        .input = @embedFile("fixtures/markdown/blank-lines.md"),
        .expected = @embedFile("fixtures/markdown/blank-lines.html"),
    },
    .{
        .name = "heading-atx",
        .input = @embedFile("fixtures/markdown/heading-atx.md"),
        .expected = @embedFile("fixtures/markdown/heading-atx.html"),
    },
    .{
        .name = "heading-closing",
        .input = @embedFile("fixtures/markdown/heading-closing.md"),
        .expected = @embedFile("fixtures/markdown/heading-closing.html"),
    },
    .{
        .name = "heading-empty",
        .input = @embedFile("fixtures/markdown/heading-empty.md"),
        .expected = @embedFile("fixtures/markdown/heading-empty.html"),
    },
    .{
        .name = "heading-not",
        .input = @embedFile("fixtures/markdown/heading-not.md"),
        .expected = @embedFile("fixtures/markdown/heading-not.html"),
    },
    .{
        .name = "heading-interrupts",
        .input = @embedFile("fixtures/markdown/heading-interrupts.md"),
        .expected = @embedFile("fixtures/markdown/heading-interrupts.html"),
    },
    .{
        .name = "heading-escaped-closing",
        .input = @embedFile("fixtures/markdown/heading-escaped-closing.md"),
        .expected = @embedFile("fixtures/markdown/heading-escaped-closing.html"),
    },
    .{
        .name = "escape-paragraph",
        .input = @embedFile("fixtures/markdown/escape-paragraph.md"),
        .expected = @embedFile("fixtures/markdown/escape-paragraph.html"),
    },
    .{
        .name = "escapes",
        .input = @embedFile("fixtures/markdown/escapes.md"),
        .expected = @embedFile("fixtures/markdown/escapes.html"),
    },
    .{
        .name = "escape-nonpunct",
        .input = @embedFile("fixtures/markdown/escape-nonpunct.md"),
        .expected = @embedFile("fixtures/markdown/escape-nonpunct.html"),
    },
    .{
        .name = "escape-escaped-backslash",
        .input = @embedFile("fixtures/markdown/escape-escaped-backslash.md"),
        .expected = @embedFile("fixtures/markdown/escape-escaped-backslash.html"),
    },
    .{
        .name = "hard-break-spaces",
        .input = @embedFile("fixtures/markdown/hard-break-spaces.md"),
        .expected = @embedFile("fixtures/markdown/hard-break-spaces.html"),
    },
    .{
        .name = "hard-break-backslash",
        .input = @embedFile("fixtures/markdown/hard-break-backslash.md"),
        .expected = @embedFile("fixtures/markdown/hard-break-backslash.html"),
    },
    .{
        .name = "soft-break-single-space",
        .input = @embedFile("fixtures/markdown/soft-break-single-space.md"),
        .expected = @embedFile("fixtures/markdown/soft-break-single-space.html"),
    },
    .{
        .name = "hard-break-last-line",
        .input = @embedFile("fixtures/markdown/hard-break-last-line.md"),
        .expected = @embedFile("fixtures/markdown/hard-break-last-line.html"),
    },
    .{
        .name = "indent-continuation",
        .input = @embedFile("fixtures/markdown/indent-continuation.md"),
        .expected = @embedFile("fixtures/markdown/indent-continuation.html"),
    },
    .{
        .name = "indent-heading",
        .input = @embedFile("fixtures/markdown/indent-heading.md"),
        .expected = @embedFile("fixtures/markdown/indent-heading.html"),
    },
    .{
        .name = "escape-special",
        .input = @embedFile("fixtures/markdown/escape-special.md"),
        .expected = @embedFile("fixtures/markdown/escape-special.html"),
    },
    // --- entities (docs: FEATURE-MATRIX "entity references") ---
    .{
        .name = "entity-text",
        .input = @embedFile("fixtures/markdown/entity-text.md"),
        .expected = @embedFile("fixtures/markdown/entity-text.html"),
    },
    .{
        .name = "entity-nonentity",
        .input = @embedFile("fixtures/markdown/entity-nonentity.md"),
        .expected = @embedFile("fixtures/markdown/entity-nonentity.html"),
    },
    .{
        .name = "entity-code",
        .input = @embedFile("fixtures/markdown/entity-code.md"),
        .expected = @embedFile("fixtures/markdown/entity-code.html"),
    },
    .{
        .name = "entity-structural",
        .input = @embedFile("fixtures/markdown/entity-structural.md"),
        .expected = @embedFile("fixtures/markdown/entity-structural.html"),
    },
    .{
        .name = "entity-info",
        .input = @embedFile("fixtures/markdown/entity-info.md"),
        .expected = @embedFile("fixtures/markdown/entity-info.html"),
    },
    // --- HTML blocks, types 6/7 (docs: FEATURE-MATRIX "raw HTML") ---
    .{
        .name = "html-block-type6",
        .input = @embedFile("fixtures/markdown/html-block-type6.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type6.html"),
    },
    .{
        .name = "html-block-type7",
        .input = @embedFile("fixtures/markdown/html-block-type7.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type7.html"),
    },
    .{
        .name = "html-block-interrupt",
        .input = @embedFile("fixtures/markdown/html-block-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/html-block-interrupt.html"),
    },
    .{
        .name = "html-block-in-quote",
        .input = @embedFile("fixtures/markdown/html-block-in-quote.md"),
        .expected = @embedFile("fixtures/markdown/html-block-in-quote.html"),
    },
    // --- HTML blocks, types 1-5 (docs: HTML-BLOCKS.md) ---
    .{
        .name = "html-block-type1",
        .input = @embedFile("fixtures/markdown/html-block-type1.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type1.html"),
    },
    .{
        .name = "html-block-type1-close",
        .input = @embedFile("fixtures/markdown/html-block-type1-close.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type1-close.html"),
    },
    .{
        .name = "html-block-type1-raw",
        .input = @embedFile("fixtures/markdown/html-block-type1-raw.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type1-raw.html"),
    },
    .{
        .name = "html-block-type2",
        .input = @embedFile("fixtures/markdown/html-block-type2.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type2.html"),
    },
    .{
        .name = "html-block-type2-close",
        .input = @embedFile("fixtures/markdown/html-block-type2-close.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type2-close.html"),
    },
    .{
        .name = "html-block-type3",
        .input = @embedFile("fixtures/markdown/html-block-type3.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type3.html"),
    },
    .{
        .name = "html-block-type4",
        .input = @embedFile("fixtures/markdown/html-block-type4.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type4.html"),
    },
    .{
        .name = "html-block-type5",
        .input = @embedFile("fixtures/markdown/html-block-type5.md"),
        .expected = @embedFile("fixtures/markdown/html-block-type5.html"),
    },
    .{
        .name = "html-block-interrupt-types",
        .input = @embedFile("fixtures/markdown/html-block-interrupt-types.md"),
        .expected = @embedFile("fixtures/markdown/html-block-interrupt-types.html"),
    },
    .{
        .name = "unicode",
        .input = @embedFile("fixtures/markdown/unicode.md"),
        .expected = @embedFile("fixtures/markdown/unicode.html"),
    },
    // --- emphasis / strong emphasis (docs/INLINE-PARSING.md §15) ---
    .{
        .name = "em-simple",
        .input = @embedFile("fixtures/markdown/em-simple.md"),
        .expected = @embedFile("fixtures/markdown/em-simple.html"),
    },
    .{
        .name = "strong-simple",
        .input = @embedFile("fixtures/markdown/strong-simple.md"),
        .expected = @embedFile("fixtures/markdown/strong-simple.html"),
    },
    .{
        .name = "em-underscore",
        .input = @embedFile("fixtures/markdown/em-underscore.md"),
        .expected = @embedFile("fixtures/markdown/em-underscore.html"),
    },
    .{
        .name = "strong-underscore",
        .input = @embedFile("fixtures/markdown/strong-underscore.md"),
        .expected = @embedFile("fixtures/markdown/strong-underscore.html"),
    },
    .{
        .name = "em-nested-strong",
        .input = @embedFile("fixtures/markdown/em-nested-strong.md"),
        .expected = @embedFile("fixtures/markdown/em-nested-strong.html"),
    },
    .{
        .name = "em-intraword",
        .input = @embedFile("fixtures/markdown/em-intraword.md"),
        .expected = @embedFile("fixtures/markdown/em-intraword.html"),
    },
    .{
        .name = "underscore-intraword",
        .input = @embedFile("fixtures/markdown/underscore-intraword.md"),
        .expected = @embedFile("fixtures/markdown/underscore-intraword.html"),
    },
    .{
        .name = "em-malformed-space",
        .input = @embedFile("fixtures/markdown/em-malformed-space.md"),
        .expected = @embedFile("fixtures/markdown/em-malformed-space.html"),
    },
    .{
        .name = "em-mod3",
        .input = @embedFile("fixtures/markdown/em-mod3.md"),
        .expected = @embedFile("fixtures/markdown/em-mod3.html"),
    },
    .{
        .name = "em-mod3-2",
        .input = @embedFile("fixtures/markdown/em-mod3-2.md"),
        .expected = @embedFile("fixtures/markdown/em-mod3-2.html"),
    },
    .{
        .name = "strong-intraword",
        .input = @embedFile("fixtures/markdown/strong-intraword.md"),
        .expected = @embedFile("fixtures/markdown/strong-intraword.html"),
    },
    .{
        .name = "strong-mod3",
        .input = @embedFile("fixtures/markdown/strong-mod3.md"),
        .expected = @embedFile("fixtures/markdown/strong-mod3.html"),
    },
    .{
        .name = "em-mod3-hello",
        .input = @embedFile("fixtures/markdown/em-mod3-hello.md"),
        .expected = @embedFile("fixtures/markdown/em-mod3-hello.html"),
    },
    .{
        .name = "em-literal",
        .input = @embedFile("fixtures/markdown/em-literal.md"),
        .expected = @embedFile("fixtures/markdown/em-literal.html"),
    },
    .{
        .name = "em-escapes",
        .input = @embedFile("fixtures/markdown/em-escapes.md"),
        .expected = @embedFile("fixtures/markdown/em-escapes.html"),
    },
    .{
        .name = "em-breaks",
        .input = @embedFile("fixtures/markdown/em-breaks.md"),
        .expected = @embedFile("fixtures/markdown/em-breaks.html"),
    },
    .{
        .name = "em-heading",
        .input = @embedFile("fixtures/markdown/em-heading.md"),
        .expected = @embedFile("fixtures/markdown/em-heading.html"),
    },
    .{
        .name = "em-unicode",
        .input = @embedFile("fixtures/markdown/em-unicode.md"),
        .expected = @embedFile("fixtures/markdown/em-unicode.html"),
    },
    .{
        .name = "code-simple",
        .input = @embedFile("fixtures/markdown/code-simple.md"),
        .expected = @embedFile("fixtures/markdown/code-simple.html"),
    },
    .{
        .name = "code-empty",
        .input = @embedFile("fixtures/markdown/code-empty.md"),
        .expected = @embedFile("fixtures/markdown/code-empty.html"),
    },
    .{
        .name = "code-run-length",
        .input = @embedFile("fixtures/markdown/code-run-length.md"),
        .expected = @embedFile("fixtures/markdown/code-run-length.html"),
    },
    .{
        .name = "code-trim",
        .input = @embedFile("fixtures/markdown/code-trim.md"),
        .expected = @embedFile("fixtures/markdown/code-trim.html"),
    },
    .{
        .name = "code-multiline",
        .input = @embedFile("fixtures/markdown/code-multiline.md"),
        .expected = @embedFile("fixtures/markdown/code-multiline.html"),
    },
    .{
        .name = "code-escapes",
        .input = @embedFile("fixtures/markdown/code-escapes.md"),
        .expected = @embedFile("fixtures/markdown/code-escapes.html"),
    },
    .{
        .name = "code-opacity",
        .input = @embedFile("fixtures/markdown/code-opacity.md"),
        .expected = @embedFile("fixtures/markdown/code-opacity.html"),
    },
    .{
        .name = "code-emphasis",
        .input = @embedFile("fixtures/markdown/code-emphasis.md"),
        .expected = @embedFile("fixtures/markdown/code-emphasis.html"),
    },
    .{
        .name = "code-heading",
        .input = @embedFile("fixtures/markdown/code-heading.md"),
        .expected = @embedFile("fixtures/markdown/code-heading.html"),
    },
    .{
        .name = "code-unicode",
        .input = @embedFile("fixtures/markdown/code-unicode.md"),
        .expected = @embedFile("fixtures/markdown/code-unicode.html"),
    },
    .{
        .name = "code-unmatched",
        .input = @embedFile("fixtures/markdown/code-unmatched.md"),
        .expected = @embedFile("fixtures/markdown/code-unmatched.html"),
    },
    .{
        .name = "code-blocks",
        .input = @embedFile("fixtures/markdown/code-blocks.md"),
        .expected = @embedFile("fixtures/markdown/code-blocks.html"),
    },
    // --- inline links (docs/INLINE-PARSING.md §6.6) ---
    .{
        .name = "link-trailing-text",
        .input = @embedFile("fixtures/markdown/link-trailing-text.md"),
        .expected = @embedFile("fixtures/markdown/link-trailing-text.html"),
    },
    .{
        .name = "link-simple",
        .input = @embedFile("fixtures/markdown/link-simple.md"),
        .expected = @embedFile("fixtures/markdown/link-simple.html"),
    },
    .{
        .name = "link-no-title",
        .input = @embedFile("fixtures/markdown/link-no-title.md"),
        .expected = @embedFile("fixtures/markdown/link-no-title.html"),
    },
    .{
        .name = "link-empty",
        .input = @embedFile("fixtures/markdown/link-empty.md"),
        .expected = @embedFile("fixtures/markdown/link-empty.html"),
    },
    .{
        .name = "link-angle-space",
        .input = @embedFile("fixtures/markdown/link-angle-space.md"),
        .expected = @embedFile("fixtures/markdown/link-angle-space.html"),
    },
    .{
        .name = "link-dest-escaped-parens",
        .input = @embedFile("fixtures/markdown/link-dest-escaped-parens.md"),
        .expected = @embedFile("fixtures/markdown/link-dest-escaped-parens.html"),
    },
    .{
        .name = "link-dest-escaped-symbols",
        .input = @embedFile("fixtures/markdown/link-dest-escaped-symbols.md"),
        .expected = @embedFile("fixtures/markdown/link-dest-escaped-symbols.html"),
    },
    .{
        .name = "link-balanced-parens",
        .input = @embedFile("fixtures/markdown/link-balanced-parens.md"),
        .expected = @embedFile("fixtures/markdown/link-balanced-parens.html"),
    },
    .{
        .name = "link-unbalanced-parens",
        .input = @embedFile("fixtures/markdown/link-unbalanced-parens.md"),
        .expected = @embedFile("fixtures/markdown/link-unbalanced-parens.html"),
    },
    .{
        .name = "link-bare-backslash",
        .input = @embedFile("fixtures/markdown/link-bare-backslash.md"),
        .expected = @embedFile("fixtures/markdown/link-bare-backslash.html"),
    },
    .{
        .name = "link-titles",
        .input = @embedFile("fixtures/markdown/link-titles.md"),
        .expected = @embedFile("fixtures/markdown/link-titles.html"),
    },
    .{
        .name = "link-nested-brackets",
        .input = @embedFile("fixtures/markdown/link-nested-brackets.md"),
        .expected = @embedFile("fixtures/markdown/link-nested-brackets.html"),
    },
    .{
        .name = "link-inline-content",
        .input = @embedFile("fixtures/markdown/link-inline-content.md"),
        .expected = @embedFile("fixtures/markdown/link-inline-content.html"),
    },
    .{
        .name = "link-no-nesting",
        .input = @embedFile("fixtures/markdown/link-no-nesting.md"),
        .expected = @embedFile("fixtures/markdown/link-no-nesting.html"),
    },
    .{
        .name = "link-precedence",
        .input = @embedFile("fixtures/markdown/link-precedence.md"),
        .expected = @embedFile("fixtures/markdown/link-precedence.html"),
    },
    .{
        .name = "link-code-span",
        .input = @embedFile("fixtures/markdown/link-code-span.md"),
        .expected = @embedFile("fixtures/markdown/link-code-span.html"),
    },
    .{
        .name = "link-escaped-bracket",
        .input = @embedFile("fixtures/markdown/link-escaped-bracket.md"),
        .expected = @embedFile("fixtures/markdown/link-escaped-bracket.html"),
    },
    .{
        .name = "link-not-a-link",
        .input = @embedFile("fixtures/markdown/link-not-a-link.md"),
        .expected = @embedFile("fixtures/markdown/link-not-a-link.html"),
    },
    .{
        .name = "link-heading",
        .input = @embedFile("fixtures/markdown/link-heading.md"),
        .expected = @embedFile("fixtures/markdown/link-heading.html"),
    },
    .{
        .name = "link-em-wrapped",
        .input = @embedFile("fixtures/markdown/link-em-wrapped.md"),
        .expected = @embedFile("fixtures/markdown/link-em-wrapped.html"),
    },
    .{
        .name = "link-quote-dest",
        .input = @embedFile("fixtures/markdown/link-quote-dest.md"),
        .expected = @embedFile("fixtures/markdown/link-quote-dest.html"),
    },
    .{
        .name = "link-multiline-title",
        .input = @embedFile("fixtures/markdown/link-multiline-title.md"),
        .expected = @embedFile("fixtures/markdown/link-multiline-title.html"),
    },
    .{
        .name = "link-entity",
        .input = @embedFile("fixtures/markdown/link-entity.md"),
        .expected = @embedFile("fixtures/markdown/link-entity.html"),
    },
    .{
        .name = "ref-full",
        .input = @embedFile("fixtures/markdown/ref-full.md"),
        .expected = @embedFile("fixtures/markdown/ref-full.html"),
    },
    .{
        .name = "ref-collapsed",
        .input = @embedFile("fixtures/markdown/ref-collapsed.md"),
        .expected = @embedFile("fixtures/markdown/ref-collapsed.html"),
    },
    .{
        .name = "ref-shortcut",
        .input = @embedFile("fixtures/markdown/ref-shortcut.md"),
        .expected = @embedFile("fixtures/markdown/ref-shortcut.html"),
    },
    .{
        .name = "ref-unicode",
        .input = @embedFile("fixtures/markdown/ref-unicode.md"),
        .expected = @embedFile("fixtures/markdown/ref-unicode.html"),
    },
    .{
        .name = "ref-case",
        .input = @embedFile("fixtures/markdown/ref-case.md"),
        .expected = @embedFile("fixtures/markdown/ref-case.html"),
    },
    .{
        .name = "ref-whitespace",
        .input = @embedFile("fixtures/markdown/ref-whitespace.md"),
        .expected = @embedFile("fixtures/markdown/ref-whitespace.html"),
    },
    .{
        .name = "ref-inline-content",
        .input = @embedFile("fixtures/markdown/ref-inline-content.md"),
        .expected = @embedFile("fixtures/markdown/ref-inline-content.html"),
    },
    .{
        .name = "ref-no-nesting",
        .input = @embedFile("fixtures/markdown/ref-no-nesting.md"),
        .expected = @embedFile("fixtures/markdown/ref-no-nesting.html"),
    },
    .{
        .name = "ref-precedence",
        .input = @embedFile("fixtures/markdown/ref-precedence.md"),
        .expected = @embedFile("fixtures/markdown/ref-precedence.html"),
    },
    .{
        .name = "ref-inline-beats",
        .input = @embedFile("fixtures/markdown/ref-inline-beats.md"),
        .expected = @embedFile("fixtures/markdown/ref-inline-beats.html"),
    },
    .{
        .name = "ref-failed-inline",
        .input = @embedFile("fixtures/markdown/ref-failed-inline.md"),
        .expected = @embedFile("fixtures/markdown/ref-failed-inline.html"),
    },
    .{
        .name = "ref-chain",
        .input = @embedFile("fixtures/markdown/ref-chain.md"),
        .expected = @embedFile("fixtures/markdown/ref-chain.html"),
    },
    .{
        .name = "ref-chain-two-defined",
        .input = @embedFile("fixtures/markdown/ref-chain-two-defined.md"),
        .expected = @embedFile("fixtures/markdown/ref-chain-two-defined.html"),
    },
    .{
        .name = "ref-escaped-label",
        .input = @embedFile("fixtures/markdown/ref-escaped-label.md"),
        .expected = @embedFile("fixtures/markdown/ref-escaped-label.html"),
    },
    .{
        .name = "ref-no-match-escapes",
        .input = @embedFile("fixtures/markdown/ref-no-match-escapes.md"),
        .expected = @embedFile("fixtures/markdown/ref-no-match-escapes.html"),
    },
    .{
        .name = "ref-invalid-brackets",
        .input = @embedFile("fixtures/markdown/ref-invalid-brackets.md"),
        .expected = @embedFile("fixtures/markdown/ref-invalid-brackets.html"),
    },
    .{
        .name = "ref-first-wins",
        .input = @embedFile("fixtures/markdown/ref-first-wins.md"),
        .expected = @embedFile("fixtures/markdown/ref-first-wins.html"),
    },
    .{
        .name = "ref-def-after",
        .input = @embedFile("fixtures/markdown/ref-def-after.md"),
        .expected = @embedFile("fixtures/markdown/ref-def-after.html"),
    },
    .{
        .name = "ref-multiline-title",
        .input = @embedFile("fixtures/markdown/ref-multiline-title.md"),
        .expected = @embedFile("fixtures/markdown/ref-multiline-title.html"),
    },
    .{
        .name = "ref-title-next-line",
        .input = @embedFile("fixtures/markdown/ref-title-next-line.md"),
        .expected = @embedFile("fixtures/markdown/ref-title-next-line.html"),
    },
    .{
        .name = "ref-no-visible",
        .input = @embedFile("fixtures/markdown/ref-no-visible.md"),
        .expected = @embedFile("fixtures/markdown/ref-no-visible.html"),
    },
    .{
        .name = "ref-cannot-interrupt",
        .input = @embedFile("fixtures/markdown/ref-cannot-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/ref-cannot-interrupt.html"),
    },
    .{
        .name = "ref-in-heading",
        .input = @embedFile("fixtures/markdown/ref-in-heading.md"),
        .expected = @embedFile("fixtures/markdown/ref-in-heading.html"),
    },
    .{
        .name = "ref-partial-paragraph",
        .input = @embedFile("fixtures/markdown/ref-partial-paragraph.md"),
        .expected = @embedFile("fixtures/markdown/ref-partial-paragraph.html"),
    },
    // --- fenced code blocks (CommonMark 0.31.2 §4.5, examples 119-147) ---
    .{
        .name = "fence-basic",
        .input = @embedFile("fixtures/markdown/fence-basic.md"),
        .expected = @embedFile("fixtures/markdown/fence-basic.html"),
    },
    .{
        .name = "fence-closers",
        .input = @embedFile("fixtures/markdown/fence-closers.md"),
        .expected = @embedFile("fixtures/markdown/fence-closers.html"),
    },
    .{
        .name = "fence-unclosed",
        .input = @embedFile("fixtures/markdown/fence-unclosed.md"),
        .expected = @embedFile("fixtures/markdown/fence-unclosed.html"),
    },
    .{
        .name = "fence-empty",
        .input = @embedFile("fixtures/markdown/fence-empty.md"),
        .expected = @embedFile("fixtures/markdown/fence-empty.html"),
    },
    .{
        .name = "fence-indentation",
        .input = @embedFile("fixtures/markdown/fence-indentation.md"),
        .expected = @embedFile("fixtures/markdown/fence-indentation.html"),
    },
    .{
        .name = "fence-closing-indent",
        .input = @embedFile("fixtures/markdown/fence-closing-indent.md"),
        .expected = @embedFile("fixtures/markdown/fence-closing-indent.html"),
    },
    .{
        .name = "fence-interrupt",
        .input = @embedFile("fixtures/markdown/fence-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/fence-interrupt.html"),
    },
    .{
        .name = "fence-adjacent-blocks",
        .input = @embedFile("fixtures/markdown/fence-adjacent-blocks.md"),
        .expected = @embedFile("fixtures/markdown/fence-adjacent-blocks.html"),
    },
    .{
        .name = "fence-info",
        .input = @embedFile("fixtures/markdown/fence-info.md"),
        .expected = @embedFile("fixtures/markdown/fence-info.html"),
    },
    .{
        .name = "fence-info-rules",
        .input = @embedFile("fixtures/markdown/fence-info-rules.md"),
        .expected = @embedFile("fixtures/markdown/fence-info-rules.html"),
    },
    .{
        .name = "fence-containers",
        .input = @embedFile("fixtures/markdown/fence-containers.md"),
        .expected = @embedFile("fixtures/markdown/fence-containers.html"),
    },
    .{
        .name = "fence-internal-space",
        .input = @embedFile("fixtures/markdown/fence-internal-space.md"),
        .expected = @embedFile("fixtures/markdown/fence-internal-space.html"),
    },
    .{
        .name = "fence-info-escape",
        .input = @embedFile("fixtures/markdown/fence-info-escape.md"),
        .expected = @embedFile("fixtures/markdown/fence-info-escape.html"),
    },
    // --- indented code blocks and tab stops (CommonMark 0.31.2 §4.4/§2.1) ---
    .{
        .name = "code-indented-chunks",
        .input = @embedFile("fixtures/markdown/code-indented-chunks.md"),
        .expected = @embedFile("fixtures/markdown/code-indented-chunks.html"),
    },
    .{
        .name = "code-indented-interrupt",
        .input = @embedFile("fixtures/markdown/code-indented-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/code-indented-interrupt.html"),
    },
    .{
        .name = "tabs-indented-code",
        .input = @embedFile("fixtures/markdown/tabs-indented-code.md"),
        .expected = @embedFile("fixtures/markdown/tabs-indented-code.html"),
    },
    .{
        .name = "tabs-containers",
        .input = @embedFile("fixtures/markdown/tabs-containers.md"),
        .expected = @embedFile("fixtures/markdown/tabs-containers.html"),
    },
    // --- thematic breaks (CommonMark 0.31.2 §4.1, examples 43-61) ---
    .{
        .name = "thematic-basic",
        .input = @embedFile("fixtures/markdown/thematic-basic.md"),
        .expected = @embedFile("fixtures/markdown/thematic-basic.html"),
    },
    .{
        .name = "thematic-spacing",
        .input = @embedFile("fixtures/markdown/thematic-spacing.md"),
        .expected = @embedFile("fixtures/markdown/thematic-spacing.html"),
    },
    .{
        .name = "thematic-precedence",
        .input = @embedFile("fixtures/markdown/thematic-precedence.md"),
        .expected = @embedFile("fixtures/markdown/thematic-precedence.html"),
    },
    .{
        .name = "thematic-malformed",
        .input = @embedFile("fixtures/markdown/thematic-malformed.md"),
        .expected = @embedFile("fixtures/markdown/thematic-malformed.html"),
    },
    // --- Setext headings (CommonMark 0.31.2 §4.3, examples 80-106) ---
    .{
        .name = "setext-basic",
        .input = @embedFile("fixtures/markdown/setext-basic.md"),
        .expected = @embedFile("fixtures/markdown/setext-basic.html"),
    },
    .{
        .name = "setext-multiline",
        .input = @embedFile("fixtures/markdown/setext-multiline.md"),
        .expected = @embedFile("fixtures/markdown/setext-multiline.html"),
    },
    .{
        .name = "setext-continuation-indent",
        .input = @embedFile("fixtures/markdown/setext-continuation-indent.md"),
        .expected = @embedFile("fixtures/markdown/setext-continuation-indent.html"),
    },
    .{
        .name = "setext-indent",
        .input = @embedFile("fixtures/markdown/setext-indent.md"),
        .expected = @embedFile("fixtures/markdown/setext-indent.html"),
    },
    .{
        .name = "setext-malformed",
        .input = @embedFile("fixtures/markdown/setext-malformed.md"),
        .expected = @embedFile("fixtures/markdown/setext-malformed.html"),
    },
    .{
        .name = "setext-final-literals",
        .input = @embedFile("fixtures/markdown/setext-final-literals.md"),
        .expected = @embedFile("fixtures/markdown/setext-final-literals.html"),
    },
    .{
        .name = "setext-containers",
        .input = @embedFile("fixtures/markdown/setext-containers.md"),
        .expected = @embedFile("fixtures/markdown/setext-containers.html"),
    },
    .{
        .name = "setext-reference",
        .input = @embedFile("fixtures/markdown/setext-reference.md"),
        .expected = @embedFile("fixtures/markdown/setext-reference.html"),
    },
    // CommonMark 0.31.2 hard-line-break example 644: a terminal backslash
    // has no following content line and therefore remains literal.
    .{
        .name = "paragraph-terminal-backslash",
        .input = @embedFile("fixtures/markdown/paragraph-terminal-backslash.md"),
        .expected = @embedFile("fixtures/markdown/paragraph-terminal-backslash.html"),
    },
    // --- block quotes (docs/BLOCKS-PARSING.md §5.1) ---
    .{
        .name = "quote-basic",
        .input = @embedFile("fixtures/markdown/quote-basic.md"),
        .expected = @embedFile("fixtures/markdown/quote-basic.html"),
    },
    .{
        .name = "quote-no-space",
        .input = @embedFile("fixtures/markdown/quote-no-space.md"),
        .expected = @embedFile("fixtures/markdown/quote-no-space.html"),
    },
    .{
        .name = "quote-indent-3",
        .input = @embedFile("fixtures/markdown/quote-indent-3.md"),
        .expected = @embedFile("fixtures/markdown/quote-indent-3.html"),
    },
    .{
        .name = "quote-lazy",
        .input = @embedFile("fixtures/markdown/quote-lazy.md"),
        .expected = @embedFile("fixtures/markdown/quote-lazy.html"),
    },
    .{
        .name = "quote-lazy-mixed",
        .input = @embedFile("fixtures/markdown/quote-lazy-mixed.md"),
        .expected = @embedFile("fixtures/markdown/quote-lazy-mixed.html"),
    },
    .{
        .name = "quote-lazy-indented",
        .input = @embedFile("fixtures/markdown/quote-lazy-indented.md"),
        .expected = @embedFile("fixtures/markdown/quote-lazy-indented.html"),
    },
    .{
        .name = "quote-empty",
        .input = @embedFile("fixtures/markdown/quote-empty.md"),
        .expected = @embedFile("fixtures/markdown/quote-empty.html"),
    },
    .{
        .name = "quote-empty-blanks",
        .input = @embedFile("fixtures/markdown/quote-empty-blanks.md"),
        .expected = @embedFile("fixtures/markdown/quote-empty-blanks.html"),
    },
    .{
        .name = "quote-initial-blank",
        .input = @embedFile("fixtures/markdown/quote-initial-blank.md"),
        .expected = @embedFile("fixtures/markdown/quote-initial-blank.html"),
    },
    .{
        .name = "quote-two",
        .input = @embedFile("fixtures/markdown/quote-two.md"),
        .expected = @embedFile("fixtures/markdown/quote-two.html"),
    },
    .{
        .name = "quote-one",
        .input = @embedFile("fixtures/markdown/quote-one.md"),
        .expected = @embedFile("fixtures/markdown/quote-one.html"),
    },
    .{
        .name = "quote-two-paragraphs",
        .input = @embedFile("fixtures/markdown/quote-two-paragraphs.md"),
        .expected = @embedFile("fixtures/markdown/quote-two-paragraphs.html"),
    },
    .{
        .name = "quote-interrupt",
        .input = @embedFile("fixtures/markdown/quote-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/quote-interrupt.html"),
    },
    .{
        .name = "quote-nested",
        .input = @embedFile("fixtures/markdown/quote-nested.md"),
        .expected = @embedFile("fixtures/markdown/quote-nested.html"),
    },
    .{
        .name = "quote-nested-lazy",
        .input = @embedFile("fixtures/markdown/quote-nested-lazy.md"),
        .expected = @embedFile("fixtures/markdown/quote-nested-lazy.html"),
    },
    .{
        .name = "quote-blank-after",
        .input = @embedFile("fixtures/markdown/quote-blank-after.md"),
        .expected = @embedFile("fixtures/markdown/quote-blank-after.html"),
    },
    .{
        .name = "quote-marker-blank-then",
        .input = @embedFile("fixtures/markdown/quote-marker-blank-then.md"),
        .expected = @embedFile("fixtures/markdown/quote-marker-blank-then.html"),
    },
    .{
        .name = "quote-definition",
        .input = @embedFile("fixtures/markdown/quote-definition.md"),
        .expected = @embedFile("fixtures/markdown/quote-definition.html"),
    },
    // --- list items and lists (CommonMark 0.31.2 §§5.2-5.3) ---
    // Each entry is one normative example, copied byte-for-byte from the
    // specification corpus. Keeping the example number beside the fixture
    // makes provenance and future scorecard changes reviewable.
    // Example 255: insufficient continuation indentation ends the item.
    .{
        .name = "list-item-indent-boundary",
        .input = @embedFile("fixtures/markdown/list-item-indent-boundary.md"),
        .expected = @embedFile("fixtures/markdown/list-item-indent-boundary.html"),
    },
    // Example 256: sufficient indentation adds a continuation paragraph.
    .{
        .name = "list-item-continuation-block",
        .input = @embedFile("fixtures/markdown/list-item-continuation-block.md"),
        .expected = @embedFile("fixtures/markdown/list-item-continuation-block.html"),
    },
    // Example 258: marker padding determines continuation indentation.
    .{
        .name = "list-item-wide-padding",
        .input = @embedFile("fixtures/markdown/list-item-wide-padding.md"),
        .expected = @embedFile("fixtures/markdown/list-item-wide-padding.html"),
    },
    // Example 259: ordered list item nested inside two block quotes.
    .{
        .name = "list-item-in-nested-quotes",
        .input = @embedFile("fixtures/markdown/list-item-in-nested-quotes.md"),
        .expected = @embedFile("fixtures/markdown/list-item-in-nested-quotes.html"),
    },
    // Example 261: a nonempty marker requires following whitespace.
    .{
        .name = "list-marker-requires-space",
        .input = @embedFile("fixtures/markdown/list-marker-requires-space.md"),
        .expected = @embedFile("fixtures/markdown/list-marker-requires-space.html"),
    },
    // Example 265: ordered markers accept at most nine digits.
    .{
        .name = "list-ordered-nine-digit-start",
        .input = @embedFile("fixtures/markdown/list-ordered-nine-digit-start.md"),
        .expected = @embedFile("fixtures/markdown/list-ordered-nine-digit-start.html"),
    },
    // Example 266: a ten-digit ordered marker remains paragraph text.
    .{
        .name = "list-ordered-ten-digit-near-miss",
        .input = @embedFile("fixtures/markdown/list-ordered-ten-digit-near-miss.md"),
        .expected = @embedFile("fixtures/markdown/list-ordered-ten-digit-near-miss.html"),
    },
    // Example 268: leading zeroes are normalized in the ordered start.
    .{
        .name = "list-ordered-leading-zeroes",
        .input = @embedFile("fixtures/markdown/list-ordered-leading-zeroes.md"),
        .expected = @embedFile("fixtures/markdown/list-ordered-leading-zeroes.html"),
    },
    // Example 281: empty bullet items remain structural list items.
    .{
        .name = "list-empty-bullet-item",
        .input = @embedFile("fixtures/markdown/list-empty-bullet-item.md"),
        .expected = @embedFile("fixtures/markdown/list-empty-bullet-item.html"),
    },
    // Example 283: empty ordered items remain structural list items.
    .{
        .name = "list-empty-ordered-item",
        .input = @embedFile("fixtures/markdown/list-empty-ordered-item.md"),
        .expected = @embedFile("fixtures/markdown/list-empty-ordered-item.html"),
    },
    // Example 285: an empty item cannot interrupt a paragraph.
    .{
        .name = "list-empty-item-no-interrupt",
        .input = @embedFile("fixtures/markdown/list-empty-item-no-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/list-empty-item-no-interrupt.html"),
    },
    // Example 291: a paragraph continuation may be lazily indented.
    .{
        .name = "list-item-lazy-continuation",
        .input = @embedFile("fixtures/markdown/list-item-lazy-continuation.md"),
        .expected = @embedFile("fixtures/markdown/list-item-lazy-continuation.html"),
    },
    // Example 294: sufficient indentation creates nested bullet lists.
    .{
        .name = "list-nested-bullets",
        .input = @embedFile("fixtures/markdown/list-nested-bullets.md"),
        .expected = @embedFile("fixtures/markdown/list-nested-bullets.html"),
    },
    // Example 296: a wide ordered marker requires a four-space sublist indent.
    .{
        .name = "list-wide-marker-nesting",
        .input = @embedFile("fixtures/markdown/list-wide-marker-nesting.md"),
        .expected = @embedFile("fixtures/markdown/list-wide-marker-nesting.html"),
    },
    // Example 299: list types may nest as the first block of an item.
    .{
        .name = "list-heterogeneous-nesting",
        .input = @embedFile("fixtures/markdown/list-heterogeneous-nesting.md"),
        .expected = @embedFile("fixtures/markdown/list-heterogeneous-nesting.html"),
    },
    // Example 301: changing bullet characters starts a new list.
    .{
        .name = "list-bullet-marker-separation",
        .input = @embedFile("fixtures/markdown/list-bullet-marker-separation.md"),
        .expected = @embedFile("fixtures/markdown/list-bullet-marker-separation.html"),
    },
    // Example 302: changing ordered delimiters starts a new list.
    .{
        .name = "list-ordered-delimiter-separation",
        .input = @embedFile("fixtures/markdown/list-ordered-delimiter-separation.md"),
        .expected = @embedFile("fixtures/markdown/list-ordered-delimiter-separation.html"),
    },
    // Example 303: a bullet list may interrupt a paragraph.
    .{
        .name = "list-bullet-interrupts-paragraph",
        .input = @embedFile("fixtures/markdown/list-bullet-interrupts-paragraph.md"),
        .expected = @embedFile("fixtures/markdown/list-bullet-interrupts-paragraph.html"),
    },
    // Example 304: an ordered list starting above one cannot interrupt.
    .{
        .name = "list-ordered-nonone-no-interrupt",
        .input = @embedFile("fixtures/markdown/list-ordered-nonone-no-interrupt.md"),
        .expected = @embedFile("fixtures/markdown/list-ordered-nonone-no-interrupt.html"),
    },
    // Example 305: an ordered list starting at one may interrupt.
    .{
        .name = "list-ordered-one-interrupts",
        .input = @embedFile("fixtures/markdown/list-ordered-one-interrupts.md"),
        .expected = @embedFile("fixtures/markdown/list-ordered-one-interrupts.html"),
    },
    // Example 306: blank lines between items make the whole list loose.
    .{
        .name = "list-loose-separated-items",
        .input = @embedFile("fixtures/markdown/list-loose-separated-items.md"),
        .expected = @embedFile("fixtures/markdown/list-loose-separated-items.html"),
    },
    // Example 319: a loose sublist does not make its outer list loose.
    .{
        .name = "list-tight-outer-loose-inner",
        .input = @embedFile("fixtures/markdown/list-tight-outer-loose-inner.md"),
        .expected = @embedFile("fixtures/markdown/list-tight-outer-loose-inner.html"),
    },
    // Example 320: a blank marker inside a quote keeps the list tight.
    .{
        .name = "list-tight-quote-child",
        .input = @embedFile("fixtures/markdown/list-tight-quote-child.md"),
        .expected = @embedFile("fixtures/markdown/list-tight-quote-child.html"),
    },
    // Example 322: a single-paragraph list is tight.
    .{
        .name = "list-tight-single-item",
        .input = @embedFile("fixtures/markdown/list-tight-single-item.md"),
        .expected = @embedFile("fixtures/markdown/list-tight-single-item.html"),
    },
    // Example 325: separated outer blocks make only the outer list loose.
    .{
        .name = "list-loose-outer-tight-inner",
        .input = @embedFile("fixtures/markdown/list-loose-outer-tight-inner.md"),
        .expected = @embedFile("fixtures/markdown/list-loose-outer-tight-inner.html"),
    },
    // Example 326: blank lines propagate looseness across outer items.
    .{
        .name = "list-loose-nested-items",
        .input = @embedFile("fixtures/markdown/list-loose-nested-items.md"),
        .expected = @embedFile("fixtures/markdown/list-loose-nested-items.html"),
    },
    // --- inline images (docs/IMAGES-PARSING.md §7) ---
    .{
        .name = "image-simple",
        .input = @embedFile("fixtures/markdown/image-simple.md"),
        .expected = @embedFile("fixtures/markdown/image-simple.html"),
    },
    .{
        .name = "image-no-title",
        .input = @embedFile("fixtures/markdown/image-no-title.md"),
        .expected = @embedFile("fixtures/markdown/image-no-title.html"),
    },
    .{
        .name = "image-title",
        .input = @embedFile("fixtures/markdown/image-title.md"),
        .expected = @embedFile("fixtures/markdown/image-title.html"),
    },
    .{
        .name = "image-angle-dest",
        .input = @embedFile("fixtures/markdown/image-angle-dest.md"),
        .expected = @embedFile("fixtures/markdown/image-angle-dest.html"),
    },
    .{
        .name = "image-empty-alt",
        .input = @embedFile("fixtures/markdown/image-empty-alt.md"),
        .expected = @embedFile("fixtures/markdown/image-empty-alt.html"),
    },
    .{
        .name = "image-escaped",
        .input = @embedFile("fixtures/markdown/image-escaped.md"),
        .expected = @embedFile("fixtures/markdown/image-escaped.html"),
    },
    .{
        .name = "image-nested",
        .input = @embedFile("fixtures/markdown/image-nested.md"),
        .expected = @embedFile("fixtures/markdown/image-nested.html"),
    },
    .{
        .name = "image-link-inside",
        .input = @embedFile("fixtures/markdown/image-link-inside.md"),
        .expected = @embedFile("fixtures/markdown/image-link-inside.html"),
    },
    .{
        .name = "image-in-link",
        .input = @embedFile("fixtures/markdown/image-in-link.md"),
        .expected = @embedFile("fixtures/markdown/image-in-link.html"),
    },
    .{
        .name = "image-alt-flatten",
        .input = @embedFile("fixtures/markdown/image-alt-flatten.md"),
        .expected = @embedFile("fixtures/markdown/image-alt-flatten.html"),
    },
    .{
        .name = "image-alt-code",
        .input = @embedFile("fixtures/markdown/image-alt-code.md"),
        .expected = @embedFile("fixtures/markdown/image-alt-code.html"),
    },
    .{
        .name = "image-alt-breaks",
        .input = @embedFile("fixtures/markdown/image-alt-breaks.md"),
        .expected = @embedFile("fixtures/markdown/image-alt-breaks.html"),
    },
    .{
        .name = "image-inactive-bracket",
        .input = @embedFile("fixtures/markdown/image-inactive-bracket.md"),
        .expected = @embedFile("fixtures/markdown/image-inactive-bracket.html"),
    },
    .{
        .name = "image-heading",
        .input = @embedFile("fixtures/markdown/image-heading.md"),
        .expected = @embedFile("fixtures/markdown/image-heading.html"),
    },
    .{
        .name = "image-emphasis",
        .input = @embedFile("fixtures/markdown/image-emphasis.md"),
        .expected = @embedFile("fixtures/markdown/image-emphasis.html"),
    },
    .{
        .name = "image-code-span",
        .input = @embedFile("fixtures/markdown/image-code-span.md"),
        .expected = @embedFile("fixtures/markdown/image-code-span.html"),
    },
    .{
        .name = "image-unclosed",
        .input = @embedFile("fixtures/markdown/image-unclosed.md"),
        .expected = @embedFile("fixtures/markdown/image-unclosed.html"),
    },
    // --- reference-style images (docs/REFERENCE-IMAGES.md §4) ---
    .{
        .name = "ref-image-full",
        .input = @embedFile("fixtures/markdown/ref-image-full.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-full.html"),
    },
    .{
        .name = "ref-image-case",
        .input = @embedFile("fixtures/markdown/ref-image-case.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-case.html"),
    },
    .{
        .name = "ref-image-collapsed",
        .input = @embedFile("fixtures/markdown/ref-image-collapsed.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-collapsed.html"),
    },
    .{
        .name = "ref-image-collapsed-em",
        .input = @embedFile("fixtures/markdown/ref-image-collapsed-em.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-collapsed-em.html"),
    },
    .{
        .name = "ref-image-collapsed-case",
        .input = @embedFile("fixtures/markdown/ref-image-collapsed-case.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-collapsed-case.html"),
    },
    .{
        .name = "ref-image-shortcut",
        .input = @embedFile("fixtures/markdown/ref-image-shortcut.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-shortcut.html"),
    },
    .{
        .name = "ref-image-shortcut-em",
        .input = @embedFile("fixtures/markdown/ref-image-shortcut-em.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-shortcut-em.html"),
    },
    .{
        .name = "ref-image-shortcut-alt",
        .input = @embedFile("fixtures/markdown/ref-image-shortcut-alt.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-shortcut-alt.html"),
    },
    .{
        .name = "ref-image-unmatched",
        .input = @embedFile("fixtures/markdown/ref-image-unmatched.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-unmatched.html"),
    },
    .{
        .name = "ref-image-def-after-use",
        .input = @embedFile("fixtures/markdown/ref-image-def-after-use.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-def-after-use.html"),
    },
    .{
        .name = "ref-image-inline-wins",
        .input = @embedFile("fixtures/markdown/ref-image-inline-wins.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-inline-wins.html"),
    },
    .{
        .name = "ref-image-in-link",
        .input = @embedFile("fixtures/markdown/ref-image-in-link.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-in-link.html"),
    },
    .{
        .name = "ref-image-first-wins",
        .input = @embedFile("fixtures/markdown/ref-image-first-wins.md"),
        .expected = @embedFile("fixtures/markdown/ref-image-first-wins.html"),
    },
    // --- autolinks (docs/AUTOLINKS.md §6.8) ---
    .{
        .name = "autolink-uri",
        .input = @embedFile("fixtures/markdown/autolink-uri.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri.html"),
    },
    .{
        .name = "autolink-uri-query",
        .input = @embedFile("fixtures/markdown/autolink-uri-query.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-query.html"),
    },
    .{
        .name = "autolink-uri-port",
        .input = @embedFile("fixtures/markdown/autolink-uri-port.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-port.html"),
    },
    .{
        .name = "autolink-uri-scheme-case",
        .input = @embedFile("fixtures/markdown/autolink-uri-scheme-case.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-scheme-case.html"),
    },
    .{
        .name = "autolink-uri-plus",
        .input = @embedFile("fixtures/markdown/autolink-uri-plus.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-plus.html"),
    },
    .{
        .name = "autolink-uri-scheme-hyphen",
        .input = @embedFile("fixtures/markdown/autolink-uri-scheme-hyphen.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-scheme-hyphen.html"),
    },
    .{
        .name = "autolink-uri-dotdot",
        .input = @embedFile("fixtures/markdown/autolink-uri-dotdot.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-dotdot.html"),
    },
    .{
        .name = "autolink-uri-localhost",
        .input = @embedFile("fixtures/markdown/autolink-uri-localhost.md"),
        .expected = @embedFile("fixtures/markdown/autolink-uri-localhost.html"),
    },
    .{
        .name = "autolink-space",
        .input = @embedFile("fixtures/markdown/autolink-space.md"),
        .expected = @embedFile("fixtures/markdown/autolink-space.html"),
    },
    .{
        .name = "autolink-escaped-backslash",
        .input = @embedFile("fixtures/markdown/autolink-escaped-backslash.md"),
        .expected = @embedFile("fixtures/markdown/autolink-escaped-backslash.html"),
    },
    .{
        .name = "autolink-email",
        .input = @embedFile("fixtures/markdown/autolink-email.md"),
        .expected = @embedFile("fixtures/markdown/autolink-email.html"),
    },
    .{
        .name = "autolink-email-plus",
        .input = @embedFile("fixtures/markdown/autolink-email-plus.md"),
        .expected = @embedFile("fixtures/markdown/autolink-email-plus.html"),
    },
    .{
        .name = "autolink-email-escaped-plus",
        .input = @embedFile("fixtures/markdown/autolink-email-escaped-plus.md"),
        .expected = @embedFile("fixtures/markdown/autolink-email-escaped-plus.html"),
    },
    .{
        .name = "autolink-empty",
        .input = @embedFile("fixtures/markdown/autolink-empty.md"),
        .expected = @embedFile("fixtures/markdown/autolink-empty.html"),
    },
    .{
        .name = "autolink-space-padded",
        .input = @embedFile("fixtures/markdown/autolink-space-padded.md"),
        .expected = @embedFile("fixtures/markdown/autolink-space-padded.html"),
    },
    .{
        .name = "autolink-short-scheme",
        .input = @embedFile("fixtures/markdown/autolink-short-scheme.md"),
        .expected = @embedFile("fixtures/markdown/autolink-short-scheme.html"),
    },
    .{
        .name = "autolink-bare-domain",
        .input = @embedFile("fixtures/markdown/autolink-bare-domain.md"),
        .expected = @embedFile("fixtures/markdown/autolink-bare-domain.html"),
    },
    .{
        .name = "autolink-bare-url",
        .input = @embedFile("fixtures/markdown/autolink-bare-url.md"),
        .expected = @embedFile("fixtures/markdown/autolink-bare-url.html"),
    },
    .{
        .name = "autolink-bare-email",
        .input = @embedFile("fixtures/markdown/autolink-bare-email.md"),
        .expected = @embedFile("fixtures/markdown/autolink-bare-email.html"),
    },
    .{
        .name = "autolink-in-sentence",
        .input = @embedFile("fixtures/markdown/autolink-in-sentence.md"),
        .expected = @embedFile("fixtures/markdown/autolink-in-sentence.html"),
    },
    .{
        .name = "autolink-in-emphasis",
        .input = @embedFile("fixtures/markdown/autolink-in-emphasis.md"),
        .expected = @embedFile("fixtures/markdown/autolink-in-emphasis.html"),
    },
    .{
        .name = "autolink-adjacent",
        .input = @embedFile("fixtures/markdown/autolink-adjacent.md"),
        .expected = @embedFile("fixtures/markdown/autolink-adjacent.html"),
    },
    .{
        .name = "autolink-link-text",
        .input = @embedFile("fixtures/markdown/autolink-link-text.md"),
        .expected = @embedFile("fixtures/markdown/autolink-link-text.html"),
    },
    .{
        .name = "autolink-email-uppercase",
        .input = @embedFile("fixtures/markdown/autolink-email-uppercase.md"),
        .expected = @embedFile("fixtures/markdown/autolink-email-uppercase.html"),
    },
    .{
        .name = "autolink-image-alt",
        .input = @embedFile("fixtures/markdown/autolink-image-alt.md"),
        .expected = @embedFile("fixtures/markdown/autolink-image-alt.html"),
    },
    // --- raw HTML (docs/RAW-HTML.md §6.6) ---
    .{
        .name = "raw-open-basic",
        .input = @embedFile("fixtures/markdown/raw-open-basic.md"),
        .expected = @embedFile("fixtures/markdown/raw-open-basic.html"),
    },
    .{
        .name = "raw-empty",
        .input = @embedFile("fixtures/markdown/raw-empty.md"),
        .expected = @embedFile("fixtures/markdown/raw-empty.html"),
    },
    .{
        .name = "raw-attrs",
        .input = @embedFile("fixtures/markdown/raw-attrs.md"),
        .expected = @embedFile("fixtures/markdown/raw-attrs.html"),
    },
    .{
        .name = "raw-ws-multiline",
        .input = @embedFile("fixtures/markdown/raw-ws-multiline.md"),
        .expected = @embedFile("fixtures/markdown/raw-ws-multiline.html"),
    },
    .{
        .name = "raw-custom",
        .input = @embedFile("fixtures/markdown/raw-custom.md"),
        .expected = @embedFile("fixtures/markdown/raw-custom.html"),
    },
    .{
        .name = "raw-closing",
        .input = @embedFile("fixtures/markdown/raw-closing.md"),
        .expected = @embedFile("fixtures/markdown/raw-closing.html"),
    },
    .{
        .name = "raw-comment-forms",
        .input = @embedFile("fixtures/markdown/raw-comment-forms.md"),
        .expected = @embedFile("fixtures/markdown/raw-comment-forms.html"),
    },
    .{
        .name = "raw-comment-multiline",
        .input = @embedFile("fixtures/markdown/raw-comment-multiline.md"),
        .expected = @embedFile("fixtures/markdown/raw-comment-multiline.html"),
    },
    .{
        .name = "raw-pi",
        .input = @embedFile("fixtures/markdown/raw-pi.md"),
        .expected = @embedFile("fixtures/markdown/raw-pi.html"),
    },
    .{
        .name = "raw-declaration",
        .input = @embedFile("fixtures/markdown/raw-declaration.md"),
        .expected = @embedFile("fixtures/markdown/raw-declaration.html"),
    },
    .{
        .name = "raw-cdata",
        .input = @embedFile("fixtures/markdown/raw-cdata.md"),
        .expected = @embedFile("fixtures/markdown/raw-cdata.html"),
    },
    .{
        .name = "raw-entity-in-attr",
        .input = @embedFile("fixtures/markdown/raw-entity-in-attr.md"),
        .expected = @embedFile("fixtures/markdown/raw-entity-in-attr.html"),
    },
    .{
        .name = "raw-backslash-in-attr",
        .input = @embedFile("fixtures/markdown/raw-backslash-in-attr.md"),
        .expected = @embedFile("fixtures/markdown/raw-backslash-in-attr.html"),
    },
    .{
        .name = "raw-illegal-name",
        .input = @embedFile("fixtures/markdown/raw-illegal-name.md"),
        .expected = @embedFile("fixtures/markdown/raw-illegal-name.html"),
    },
    .{
        .name = "raw-illegal-attr-name",
        .input = @embedFile("fixtures/markdown/raw-illegal-attr-name.md"),
        .expected = @embedFile("fixtures/markdown/raw-illegal-attr-name.html"),
    },
    .{
        .name = "raw-illegal-attr-value",
        .input = @embedFile("fixtures/markdown/raw-illegal-attr-value.md"),
        .expected = @embedFile("fixtures/markdown/raw-illegal-attr-value.html"),
    },
    .{
        .name = "raw-illegal-ws",
        .input = @embedFile("fixtures/markdown/raw-illegal-ws.md"),
        .expected = @embedFile("fixtures/markdown/raw-illegal-ws.html"),
    },
    .{
        .name = "raw-missing-ws",
        .input = @embedFile("fixtures/markdown/raw-missing-ws.md"),
        .expected = @embedFile("fixtures/markdown/raw-missing-ws.html"),
    },
    .{
        .name = "raw-closing-attr",
        .input = @embedFile("fixtures/markdown/raw-closing-attr.md"),
        .expected = @embedFile("fixtures/markdown/raw-closing-attr.html"),
    },
    // --- GFM tables extension (docs/TABLES.md); each entry is one
    // normative GFM §4.10 example, byte-for-byte from the GFM spec, plus
    // container and inline-content coverage. ---
    .{
        .name = "table-basic",
        .input = @embedFile("fixtures/markdown/table-basic.md"),
        .expected = @embedFile("fixtures/markdown/table-basic.html"),
    },
    .{
        .name = "table-alignment",
        .input = @embedFile("fixtures/markdown/table-alignment.md"),
        .expected = @embedFile("fixtures/markdown/table-alignment.html"),
    },
    .{
        .name = "table-escaped-pipes",
        .input = @embedFile("fixtures/markdown/table-escaped-pipes.md"),
        .expected = @embedFile("fixtures/markdown/table-escaped-pipes.html"),
    },
    .{
        .name = "table-break-blockquote",
        .input = @embedFile("fixtures/markdown/table-break-blockquote.md"),
        .expected = @embedFile("fixtures/markdown/table-break-blockquote.html"),
    },
    .{
        .name = "table-body-rows-vary",
        .input = @embedFile("fixtures/markdown/table-body-rows-vary.md"),
        .expected = @embedFile("fixtures/markdown/table-body-rows-vary.html"),
    },
    .{
        .name = "table-mismatch",
        .input = @embedFile("fixtures/markdown/table-mismatch.md"),
        .expected = @embedFile("fixtures/markdown/table-mismatch.html"),
    },
    .{
        .name = "table-pad-truncate",
        .input = @embedFile("fixtures/markdown/table-pad-truncate.md"),
        .expected = @embedFile("fixtures/markdown/table-pad-truncate.html"),
    },
    .{
        .name = "table-no-body",
        .input = @embedFile("fixtures/markdown/table-no-body.md"),
        .expected = @embedFile("fixtures/markdown/table-no-body.html"),
    },
    .{
        .name = "table-in-quote",
        .input = @embedFile("fixtures/markdown/table-in-quote.md"),
        .expected = @embedFile("fixtures/markdown/table-in-quote.html"),
    },
    .{
        .name = "table-inline-content",
        .input = @embedFile("fixtures/markdown/table-inline-content.md"),
        .expected = @embedFile("fixtures/markdown/table-inline-content.html"),
    },
    .{
        .name = "table-literal",
        .input = @embedFile("fixtures/markdown/table-literal.md"),
        .expected = @embedFile("fixtures/markdown/table-literal.html"),
    },
};

/// Markdown-extension fixtures (footnotes, definition lists, heading
/// attribute lists, heading ids): parsed with all extensions enabled and
/// rendered with `heading_ids` + `footnotes` (docs/MARKDOWN-EXTENSIONS.md).
/// These are opt-in extensions, so they live outside the byte-exact
/// CommonMark fixture list above.
const MarkdownExtFixture = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

const markdown_ext_fixtures = [_]MarkdownExtFixture{
    .{
        .name = "ext-definition-list",
        .input = @embedFile("fixtures/markdown/ext-definition-list.md"),
        .expected = @embedFile("fixtures/markdown/ext-definition-list.html"),
    },
    .{
        .name = "ext-footnotes",
        .input = @embedFile("fixtures/markdown/ext-footnotes.md"),
        .expected = @embedFile("fixtures/markdown/ext-footnotes.html"),
    },
    .{
        .name = "ext-heading-ids",
        .input = @embedFile("fixtures/markdown/ext-heading-ids.md"),
        .expected = @embedFile("fixtures/markdown/ext-heading-ids.html"),
    },
    .{
        .name = "ext-strikethrough",
        .input = @embedFile("fixtures/markdown/ext-strikethrough.md"),
        .expected = @embedFile("fixtures/markdown/ext-strikethrough.html"),
    },
    .{
        .name = "wikilink-basic",
        .input = @embedFile("fixtures/markdown/wikilink-basic.md"),
        .expected = @embedFile("fixtures/markdown/wikilink-basic.html"),
    },
    .{
        .name = "wikilink-literal",
        .input = @embedFile("fixtures/markdown/wikilink-literal.md"),
        .expected = @embedFile("fixtures/markdown/wikilink-literal.html"),
    },
    .{
        .name = "wikilink-precedence",
        .input = @embedFile("fixtures/markdown/wikilink-precedence.md"),
        .expected = @embedFile("fixtures/markdown/wikilink-precedence.html"),
    },
    .{
        .name = "wikilink-escapes",
        .input = @embedFile("fixtures/markdown/wikilink-escapes.md"),
        .expected = @embedFile("fixtures/markdown/wikilink-escapes.html"),
    },
    .{
        .name = "callout-basic",
        .input = @embedFile("fixtures/markdown/callout-basic.md"),
        .expected = @embedFile("fixtures/markdown/callout-basic.html"),
    },
    .{
        .name = "callout-types",
        .input = @embedFile("fixtures/markdown/callout-types.md"),
        .expected = @embedFile("fixtures/markdown/callout-types.html"),
    },
    .{
        .name = "callout-body",
        .input = @embedFile("fixtures/markdown/callout-body.md"),
        .expected = @embedFile("fixtures/markdown/callout-body.html"),
    },
    .{
        .name = "callout-literal",
        .input = @embedFile("fixtures/markdown/callout-literal.md"),
        .expected = @embedFile("fixtures/markdown/callout-literal.html"),
    },
    .{
        .name = "smartypants-basic",
        .input = @embedFile("fixtures/markdown/smartypants-basic.md"),
        .expected = @embedFile("fixtures/markdown/smartypants-basic.html"),
    },
    .{
        .name = "smartypants-exempt",
        .input = @embedFile("fixtures/markdown/smartypants-exempt.md"),
        .expected = @embedFile("fixtures/markdown/smartypants-exempt.html"),
    },
    .{
        .name = "smartypants-scopes",
        .input = @embedFile("fixtures/markdown/smartypants-scopes.md"),
        .expected = @embedFile("fixtures/markdown/smartypants-scopes.html"),
    },
    .{
        .name = "cross-callout-title",
        .input = @embedFile("fixtures/markdown/cross-callout-title.md"),
        .expected = @embedFile("fixtures/markdown/cross-callout-title.html"),
    },
    .{
        .name = "cross-smartypants-scopes",
        .input = @embedFile("fixtures/markdown/cross-smartypants-scopes.md"),
        .expected = @embedFile("fixtures/markdown/cross-smartypants-scopes.html"),
    },
    .{
        .name = "cross-callout-edges",
        .input = @embedFile("fixtures/markdown/cross-callout-edges.md"),
        .expected = @embedFile("fixtures/markdown/cross-callout-edges.html"),
    },
};

const TextileFixture = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

// Frontmatter-extension fixtures (docs/FRONTMATTER.md §10): parsed with
// `ParseOptions.frontmatter` on and rendered with default render options.
// Each entry carries the fence dialect its input uses.
const MarkdownFmFixture = struct {
    name: []const u8,
    mode: oliver.frontmatter.Option,
    input: []const u8,
    expected: []const u8,
};

const markdown_fm_fixtures = [_]MarkdownFmFixture{
    .{
        .name = "frontmatter-yaml",
        .mode = .yaml,
        .input = @embedFile("fixtures/markdown/frontmatter-yaml.md"),
        .expected = @embedFile("fixtures/markdown/frontmatter-yaml.html"),
    },
    .{
        .name = "frontmatter-toml",
        .mode = .toml,
        .input = @embedFile("fixtures/markdown/frontmatter-toml.md"),
        .expected = @embedFile("fixtures/markdown/frontmatter-toml.html"),
    },
    .{
        .name = "frontmatter-nested",
        .mode = .yaml,
        .input = @embedFile("fixtures/markdown/frontmatter-nested.md"),
        .expected = @embedFile("fixtures/markdown/frontmatter-nested.html"),
    },
    .{
        .name = "frontmatter-out-of-subset",
        .mode = .yaml,
        .input = @embedFile("fixtures/markdown/frontmatter-out-of-subset.md"),
        .expected = @embedFile("fixtures/markdown/frontmatter-out-of-subset.html"),
    },
    .{
        .name = "frontmatter-unclosed",
        .mode = .yaml,
        .input = @embedFile("fixtures/markdown/frontmatter-unclosed.md"),
        .expected = @embedFile("fixtures/markdown/frontmatter-unclosed.html"),
    },
};

// Textile frontmatter fixture pair (docs/FRONTMATTER.md §10): parsed with
// `.frontmatter = .yaml`, rendered with default render options.
const textile_fm_fixtures = [_]TextileFixture{
    .{
        .name = "frontmatter-textile",
        .input = @embedFile("fixtures/textile/frontmatter-textile.textile"),
        .expected = @embedFile("fixtures/textile/frontmatter-textile.html"),
    },
};

const textile_fixtures = [_]TextileFixture{
    .{
        .name = "paragraph",
        .input = @embedFile("fixtures/textile/paragraph.textile"),
        .expected = @embedFile("fixtures/textile/paragraph.html"),
    },
    .{
        .name = "two-paragraphs",
        .input = @embedFile("fixtures/textile/two-paragraphs.textile"),
        .expected = @embedFile("fixtures/textile/two-paragraphs.html"),
    },
    .{
        .name = "linebreak",
        .input = @embedFile("fixtures/textile/linebreak.textile"),
        .expected = @embedFile("fixtures/textile/linebreak.html"),
    },
    .{
        .name = "p-prefix",
        .input = @embedFile("fixtures/textile/p-prefix.textile"),
        .expected = @embedFile("fixtures/textile/p-prefix.html"),
    },
    // Oliver policy: recognized block signatures interrupt without a blank
    // line; the historical references do not define every adjacency.
    .{
        .name = "p-interrupt",
        .input = @embedFile("fixtures/textile/p-interrupt.textile"),
        .expected = @embedFile("fixtures/textile/p-interrupt.html"),
    },
    .{
        .name = "heading",
        .input = @embedFile("fixtures/textile/heading.textile"),
        .expected = @embedFile("fixtures/textile/heading.html"),
    },
    .{
        .name = "heading-not",
        .input = @embedFile("fixtures/textile/heading-not.textile"),
        .expected = @embedFile("fixtures/textile/heading-not.html"),
    },
    .{
        .name = "mixed",
        .input = @embedFile("fixtures/textile/mixed.textile"),
        .expected = @embedFile("fixtures/textile/mixed.html"),
    },
    .{
        .name = "interrupt",
        .input = @embedFile("fixtures/textile/interrupt.textile"),
        .expected = @embedFile("fixtures/textile/interrupt.html"),
    },
    // Single-period blockquote structure/continuation comes from Hobix,
    // Movable Type Textile 2, and the current Textile documentation.
    .{
        .name = "bq-basic",
        .input = @embedFile("fixtures/textile/bq-basic.textile"),
        .expected = @embedFile("fixtures/textile/bq-basic.html"),
    },
    .{
        .name = "bq-multiline",
        .input = @embedFile("fixtures/textile/bq-multiline.textile"),
        .expected = @embedFile("fixtures/textile/bq-multiline.html"),
    },
    .{
        .name = "bq-surrounded",
        .input = @embedFile("fixtures/textile/bq-surrounded.textile"),
        .expected = @embedFile("fixtures/textile/bq-surrounded.html"),
    },
    .{
        .name = "bq-interrupt",
        .input = @embedFile("fixtures/textile/bq-interrupt.textile"),
        .expected = @embedFile("fixtures/textile/bq-interrupt.html"),
    },
    // This fixture pins the literal fallback shapes: empty `bq.` and `bq..`
    // signatures, a period without a following space, and a `bq.:` citation
    // with no whitespace after the URL. Valid citations are covered by the
    // `bq-cite-*` fixtures (docs/TEXTILE-PARITY.md §12).
    .{
        .name = "bq-malformed",
        .input = @embedFile("fixtures/textile/bq-malformed.textile"),
        .expected = @embedFile("fixtures/textile/bq-malformed.html"),
    },
    // The current Textile docs' citation example byte-for-byte: `bq.:URL`
    // renders the URL as the blockquote's `cite` attribute with the inner
    // paragraph unmarked (docs/TEXTILE-PARITY.md §12).
    .{
        .name = "bq-cite-basic",
        .input = @embedFile("fixtures/textile/bq-cite-basic.textile"),
        .expected = @embedFile("fixtures/textile/bq-cite-basic.html"),
    },
    // The §8 block modifiers combine with the citation (cite attribute
    // first, then attrs in the fixed order), and sentence punctuation after
    // the URL is trimmed like an inline link destination.
    .{
        .name = "bq-cite-mods",
        .input = @embedFile("fixtures/textile/bq-cite-mods.textile"),
        .expected = @embedFile("fixtures/textile/bq-cite-mods.html"),
    },
    // Malformed citation shapes stay literal: a space after the colon, no
    // content, no URL, and the undocumented `bq..:URL` extended-citation
    // combination.
    .{
        .name = "bq-cite-literal",
        .input = @embedFile("fixtures/textile/bq-cite-literal.textile"),
        .expected = @embedFile("fixtures/textile/bq-cite-literal.html"),
    },
    // A citation signature is a block signature: it terminates an open
    // extended `bq..` quote, which renders with its own cite.
    .{
        .name = "bq-cite-extended",
        .input = @embedFile("fixtures/textile/bq-cite-extended.textile"),
        .expected = @embedFile("fixtures/textile/bq-cite-extended.html"),
    },
    .{
        .name = "bq-unicode",
        .input = @embedFile("fixtures/textile/bq-unicode.textile"),
        .expected = @embedFile("fixtures/textile/bq-unicode.html"),
    },
    // Oliver consistently accepts tabs as block-signature separators.
    .{
        .name = "bq-tab",
        .input = @embedFile("fixtures/textile/bq-tab.textile"),
        .expected = @embedFile("fixtures/textile/bq-tab.html"),
    },
    // Same-line Textile @code@ phrases use the clean-room boundary and
    // fallback contract in docs/TEXTILE-INLINE-CODE.md.
    .{
        .name = "code-basic",
        .input = @embedFile("fixtures/textile/code-basic.textile"),
        .expected = @embedFile("fixtures/textile/code-basic.html"),
    },
    .{
        .name = "code-opacity",
        .input = @embedFile("fixtures/textile/code-opacity.textile"),
        .expected = @embedFile("fixtures/textile/code-opacity.html"),
    },
    .{
        .name = "code-contexts",
        .input = @embedFile("fixtures/textile/code-contexts.textile"),
        .expected = @embedFile("fixtures/textile/code-contexts.html"),
    },
    .{
        .name = "code-boundaries",
        .input = @embedFile("fixtures/textile/code-boundaries.textile"),
        .expected = @embedFile("fixtures/textile/code-boundaries.html"),
    },
    .{
        .name = "code-literal",
        .input = @embedFile("fixtures/textile/code-literal.textile"),
        .expected = @embedFile("fixtures/textile/code-literal.html"),
    },
    .{
        .name = "code-same-line",
        .input = @embedFile("fixtures/textile/code-same-line.textile"),
        .expected = @embedFile("fixtures/textile/code-same-line.html"),
    },
    .{
        .name = "special-chars",
        .input = @embedFile("fixtures/textile/special-chars.textile"),
        .expected = @embedFile("fixtures/textile/special-chars.html"),
    },
    .{
        .name = "unicode",
        .input = @embedFile("fixtures/textile/unicode.textile"),
        .expected = @embedFile("fixtures/textile/unicode.html"),
    },
    // --- phrase modifiers (Textile 2 inline formatting; both references) ---
    .{
        .name = "phrase-modifiers",
        .input = @embedFile("fixtures/textile/phrase-modifiers.textile"),
        .expected = @embedFile("fixtures/textile/phrase-modifiers.html"),
    },
    .{
        .name = "phrase-nesting",
        .input = @embedFile("fixtures/textile/phrase-nesting.textile"),
        .expected = @embedFile("fixtures/textile/phrase-nesting.html"),
    },
    .{
        .name = "phrase-boundaries",
        .input = @embedFile("fixtures/textile/phrase-boundaries.textile"),
        .expected = @embedFile("fixtures/textile/phrase-boundaries.html"),
    },
    .{
        .name = "phrase-big-small",
        .input = @embedFile("fixtures/textile/phrase-big-small.textile"),
        .expected = @embedFile("fixtures/textile/phrase-big-small.html"),
    },
    .{
        .name = "phrase-in-heading",
        .input = @embedFile("fixtures/textile/phrase-in-heading.textile"),
        .expected = @embedFile("fixtures/textile/phrase-in-heading.html"),
    },
    // --- links (Textile 2; Hobix "External References") ---
    .{
        .name = "link-basic",
        .input = @embedFile("fixtures/textile/link-basic.textile"),
        .expected = @embedFile("fixtures/textile/link-basic.html"),
    },
    .{
        .name = "link-title",
        .input = @embedFile("fixtures/textile/link-title.textile"),
        .expected = @embedFile("fixtures/textile/link-title.html"),
    },
    .{
        .name = "link-bracket-trick",
        .input = @embedFile("fixtures/textile/link-bracket-trick.textile"),
        .expected = @embedFile("fixtures/textile/link-bracket-trick.html"),
    },
    .{
        .name = "link-literal",
        .input = @embedFile("fixtures/textile/link-literal.textile"),
        .expected = @embedFile("fixtures/textile/link-literal.html"),
    },
    // --- link aliases (Hobix "External References: Link Aliases"; Textile
    // 2 "Links") ---
    .{
        .name = "link-alias-basic",
        .input = @embedFile("fixtures/textile/link-alias-basic.textile"),
        .expected = @embedFile("fixtures/textile/link-alias-basic.html"),
    },
    // Textile 2's definition block: several `[alias]url` lines in a block
    // of their own, referenced from elsewhere in the document.
    .{
        .name = "link-alias-def-block",
        .input = @embedFile("fixtures/textile/link-alias-def-block.textile"),
        .expected = @embedFile("fixtures/textile/link-alias-def-block.html"),
    },
    // First definition wins; matching is case-sensitive; an undefined
    // alias is an ordinary relative URL.
    .{
        .name = "link-alias-precedence",
        .input = @embedFile("fixtures/textile/link-alias-precedence.textile"),
        .expected = @embedFile("fixtures/textile/link-alias-precedence.html"),
    },
    // Shapes that are not definitions stay ordinary text: `[1]` with a
    // space, an empty alias, no URL, a URL with whitespace, and a
    // def-shaped substring inside a line.
    .{
        .name = "link-alias-literal",
        .input = @embedFile("fixtures/textile/link-alias-literal.textile"),
        .expected = @embedFile("fixtures/textile/link-alias-literal.html"),
    },
    // --- images (Hobix "External References"; Textile 2 "Images") ---
    .{
        .name = "image-basic",
        .input = @embedFile("fixtures/textile/image-basic.textile"),
        .expected = @embedFile("fixtures/textile/image-basic.html"),
    },
    .{
        .name = "image-linked",
        .input = @embedFile("fixtures/textile/image-linked.textile"),
        .expected = @embedFile("fixtures/textile/image-linked.html"),
    },
    .{
        .name = "image-literal",
        .input = @embedFile("fixtures/textile/image-literal.textile"),
        .expected = @embedFile("fixtures/textile/image-literal.html"),
    },
    // --- lists (Hobix "Lists"; Textile 2 "Lists") ---
    .{
        .name = "list-basic",
        .input = @embedFile("fixtures/textile/list-basic.textile"),
        .expected = @embedFile("fixtures/textile/list-basic.html"),
    },
    .{
        .name = "list-nested",
        .input = @embedFile("fixtures/textile/list-nested.textile"),
        .expected = @embedFile("fixtures/textile/list-nested.html"),
    },
    .{
        .name = "list-mixed",
        .input = @embedFile("fixtures/textile/list-mixed.textile"),
        .expected = @embedFile("fixtures/textile/list-mixed.html"),
    },
    // --- composition and opacity across inline families ---
    .{
        .name = "inline-composition",
        .input = @embedFile("fixtures/textile/inline-composition.textile"),
        .expected = @embedFile("fixtures/textile/inline-composition.html"),
    },
    // --- tables (Hobix "Tables"; Textile 2 "Tables") ---
    .{
        .name = "table-basic",
        .input = @embedFile("fixtures/textile/table-basic.textile"),
        .expected = @embedFile("fixtures/textile/table-basic.html"),
    },
    .{
        .name = "table-header",
        .input = @embedFile("fixtures/textile/table-header.textile"),
        .expected = @embedFile("fixtures/textile/table-header.html"),
    },
    // Hobix "Cell Attributes": alignment, justification, and vertical
    // alignment render as CSS styles on flat rows.
    .{
        .name = "table-cell-attributes",
        .input = @embedFile("fixtures/textile/table-cell-attributes.textile"),
        .expected = @embedFile("fixtures/textile/table-cell-attributes.html"),
    },
    .{
        .name = "table-colspan",
        .input = @embedFile("fixtures/textile/table-colspan.textile"),
        .expected = @embedFile("fixtures/textile/table-colspan.html"),
    },
    .{
        .name = "table-rowspan",
        .input = @embedFile("fixtures/textile/table-rowspan.textile"),
        .expected = @embedFile("fixtures/textile/table-rowspan.html"),
    },
    .{
        .name = "table-cell-style",
        .input = @embedFile("fixtures/textile/table-cell-style.textile"),
        .expected = @embedFile("fixtures/textile/table-cell-style.html"),
    },
    // Hobix "Table and Row Attributes": the signature on its own line and
    // a `. `-terminated row-attribute line.
    .{
        .name = "table-signature",
        .input = @embedFile("fixtures/textile/table-signature.textile"),
        .expected = @embedFile("fixtures/textile/table-signature.html"),
    },
    .{
        .name = "table-row-attrs",
        .input = @embedFile("fixtures/textile/table-row-attrs.textile"),
        .expected = @embedFile("fixtures/textile/table-row-attrs.html"),
    },
    // The Textile 2 complex example: signature + first row on one line,
    // pipe-terminated row modifiers, rowspan, and a styled header cell
    // (Oliver's pinned output; both references give no literal HTML for it).
    .{
        .name = "table-textile2-complex",
        .input = @embedFile("fixtures/textile/table-textile2-complex.textile"),
        .expected = @embedFile("fixtures/textile/table-textile2-complex.html"),
    },
    // Textile 2's header-alignment propagation rule: a header cell's
    // alignment becomes the default for the cells below it in the column.
    .{
        .name = "table-propagation",
        .input = @embedFile("fixtures/textile/table-propagation.textile"),
        .expected = @embedFile("fixtures/textile/table-propagation.html"),
    },
    // Malformed rows and signatures stay literal under the recorded
    // contract: no closing pipe, modifiers without the `. ` terminator,
    // `table.` with non-row text, unclosed braces.
    .{
        .name = "table-literal",
        .input = @embedFile("fixtures/textile/table-literal.textile"),
        .expected = @embedFile("fixtures/textile/table-literal.html"),
    },
    .{
        .name = "table-inline",
        .input = @embedFile("fixtures/textile/table-inline.textile"),
        .expected = @embedFile("fixtures/textile/table-inline.html"),
    },
    .{
        .name = "table-close",
        .input = @embedFile("fixtures/textile/table-close.textile"),
        .expected = @embedFile("fixtures/textile/table-close.html"),
    },
    // --- block attributes (Hobix "Attributes: Block Attributes /
    // Block Alignments"; Textile 2 "Block Attributes") ---
    // The Hobix §4 battery: class, id, class#id, style, lang, the four
    // alignments, and `(`/`)` indentation on paragraph signatures.
    .{
        .name = "block-attr-basic",
        .input = @embedFile("fixtures/textile/block-attr-basic.textile"),
        .expected = @embedFile("fixtures/textile/block-attr-basic.html"),
    },
    // Combined modifiers: `h2()>.`, `h3()>[no]{color:red}.`, and mixed
    // class/lang on one signature.
    .{
        .name = "block-attr-combined",
        .input = @embedFile("fixtures/textile/block-attr-combined.textile"),
        .expected = @embedFile("fixtures/textile/block-attr-combined.html"),
    },
    // Blockquote signatures carry attrs on the `<blockquote>`; the inner
    // paragraph stays unmarked.
    .{
        .name = "block-attr-bq",
        .input = @embedFile("fixtures/textile/block-attr-bq.textile"),
        .expected = @embedFile("fixtures/textile/block-attr-bq.html"),
    },
    // Headings with class/lang/style attrs alongside plain `hN.` forms.
    .{
        .name = "block-attr-heading",
        .input = @embedFile("fixtures/textile/block-attr-heading.textile"),
        .expected = @embedFile("fixtures/textile/block-attr-heading.html"),
    },
    // Malformed signatures stay literal: unterminated class, no space
    // after the period, doubled periods, the deferred `bq..`/`bq:` forms,
    // and a non-`hN` heading marker.
    .{
        .name = "block-attr-literal",
        .input = @embedFile("fixtures/textile/block-attr-literal.textile"),
        .expected = @embedFile("fixtures/textile/block-attr-literal.html"),
    },
    // --- block code / preformatted text (Textile 2 "bc"; current Textile
    // docs "pre.") ---
    // `bc.` collects every non-blank line verbatim until a blank line
    // (signature-shaped lines stay code), and renders escaped
    // `<pre><code>`.
    .{
        .name = "code-block-bc",
        .input = @embedFile("fixtures/textile/code-block-bc.textile"),
        .expected = @embedFile("fixtures/textile/code-block-bc.html"),
    },
    // `pre.` is verbatim preformatted text: HTML is preserved, no
    // escaping, no `<code>` wrapper.
    .{
        .name = "code-block-pre",
        .input = @embedFile("fixtures/textile/code-block-pre.textile"),
        .expected = @embedFile("fixtures/textile/code-block-pre.html"),
    },
    // Block-attribute modifiers work on code signatures, landing on the
    // `<pre>` element (`bc{...}.`, `pre(...)[lang].`).
    .{
        .name = "code-block-attrs",
        .input = @embedFile("fixtures/textile/code-block-attrs.textile"),
        .expected = @embedFile("fixtures/textile/code-block-attrs.html"),
    },
    // Empty signatures, near misses, and plain words stay literal
    // paragraphs: `bc. `, `pre.`, `bcd.`, `bc`, `prelude.`.
    .{
        .name = "code-block-literal",
        .input = @embedFile("fixtures/textile/code-block-literal.textile"),
        .expected = @embedFile("fixtures/textile/code-block-literal.html"),
    },
    // --- extended blocks (Textile 2 "Extended Blocks"; current Textile
    // docs "Extended blocks") ---
    // `bq..` stays active across blank lines: unmarked lines continue the
    // quote, blank lines separate paragraphs inside one `<blockquote>`,
    // and a block signature (`p.`) ends it.
    .{
        .name = "extended-bq",
        .input = @embedFile("fixtures/textile/extended-bq.textile"),
        .expected = @embedFile("fixtures/textile/extended-bq.html"),
    },
    // `bc..` keeps blank lines as verbatim code content (escaped
    // `<pre><code>`), ending at the next signature.
    .{
        .name = "extended-bc",
        .input = @embedFile("fixtures/textile/extended-bc.textile"),
        .expected = @embedFile("fixtures/textile/extended-bc.html"),
    },
    // `pre..` is the same extended form, verbatim `<pre>` preserving HTML
    // and blank lines.
    .{
        .name = "extended-pre",
        .input = @embedFile("fixtures/textile/extended-pre.textile"),
        .expected = @embedFile("fixtures/textile/extended-pre.html"),
    },
    // Empty extended signatures stay literal, `p..`/`h1..` are not
    // extended signatures, and `bq.` still ends at the first blank line.
    .{
        .name = "extended-literal",
        .input = @embedFile("fixtures/textile/extended-literal.textile"),
        .expected = @embedFile("fixtures/textile/extended-literal.html"),
    },
    // The Hobix footnote battery: `[N]` references and `fnN.` blocks, with
    // the Textile 2 `class="footnote"` on both sides (docs/TEXTILE-PARITY.md
    // §11).
    .{
        .name = "footnote-basic",
        .input = @embedFile("fixtures/textile/footnote-basic.textile"),
        .expected = @embedFile("fixtures/textile/footnote-basic.html"),
    },
    // Multiple footnotes in one line and numbered blocks stay in order.
    .{
        .name = "footnote-multi",
        .input = @embedFile("fixtures/textile/footnote-multi.textile"),
        .expected = @embedFile("fixtures/textile/footnote-multi.html"),
    },
    // The §8 block modifiers apply to footnote signatures; the structural
    // `class="footnote" id="fnN"` always come first and user style/lang
    // follow them.
    .{
        .name = "footnote-attr",
        .input = @embedFile("fixtures/textile/footnote-attr.textile"),
        .expected = @embedFile("fixtures/textile/footnote-attr.html"),
    },
    // Non-digit brackets, a letter after digits, empty `fnN.`/`fnN<mods>.`
    // signatures, and `fnx.` all stay literal.
    .{
        .name = "footnote-literal",
        .input = @embedFile("fixtures/textile/footnote-literal.textile"),
        .expected = @embedFile("fixtures/textile/footnote-literal.html"),
    },
    // The character-replacement battery: the Hobix examples byte-for-byte
    // (curly quotes, em/en dashes, ellipsis, dimension sign, (TM)/(R)/(C))
    // plus the current docs' case-insensitive (c)/(r)/(tm), the fraction/
    // degree/plus-minus macros, and the apostrophe rules
    // (docs/TEXTILE-PARITY.md §13).
    .{
        .name = "char-replace-basic",
        .input = @embedFile("fixtures/textile/char-replace-basic.textile"),
        .expected = @embedFile("fixtures/textile/char-replace-basic.html"),
    },
    // Replacements apply inside phrase content and link display text;
    // HTML-looking `<...>` regions and `@code@` payloads stay verbatim.
    .{
        .name = "char-replace-context",
        .input = @embedFile("fixtures/textile/char-replace-context.textile"),
        .expected = @embedFile("fixtures/textile/char-replace-context.html"),
    },
    // Literal fallbacks: letter-touching hyphens, `x` not between digits,
    // `---`/`....` runs (left-to-right), and paren forms that are not the
    // documented macros.
    .{
        .name = "char-replace-literal",
        .input = @embedFile("fixtures/textile/char-replace-literal.textile"),
        .expected = @embedFile("fixtures/textile/char-replace-literal.html"),
    },
    // The `{...}` character-macro table (Textile 2 "Character
    // Replacements"): the documented forms with their mirrored orders,
    // inside link display text, and the literal fallbacks — undocumented
    // shapes, unclosed braces, opacity inside `@code@`/`==`, and the
    // brace-edge rule that keeps `{*}`/`{-L}` whole for the macro pass
    // (docs/TEXTILE-PARITY.md §18).
    .{
        .name = "char-macro-basic",
        .input = @embedFile("fixtures/textile/char-macro-basic.textile"),
        .expected = @embedFile("fixtures/textile/char-macro-basic.html"),
    },
    .{
        .name = "char-macro-literal",
        .input = @embedFile("fixtures/textile/char-macro-literal.textile"),
        .expected = @embedFile("fixtures/textile/char-macro-literal.html"),
    },
    // Span phrase attributes (Hobix "Phrase Attributes": all block
    // attributes apply just inside the opening modifier; Textile 2
    // "Inline formatting operators accept the following modifiers"):
    // `%[es]cabeza%` → `<span lang="es">`, the fixed render order for a
    // combined run, nested phrases, and the literal fallbacks — malformed
    // runs, whitespace/empty content, and a `%` inside a style value
    // (docs/TEXTILE-PARITY.md §18).
    .{
        .name = "span-attr-basic",
        .input = @embedFile("fixtures/textile/span-attr-basic.textile"),
        .expected = @embedFile("fixtures/textile/span-attr-basic.html"),
    },
    .{
        .name = "span-attr-literal",
        .input = @embedFile("fixtures/textile/span-attr-literal.textile"),
        .expected = @embedFile("fixtures/textile/span-attr-literal.html"),
    },
    // The same phrase-attribute machinery on the other operators (Hobix
    // "Phrase Attributes": "all block attributes can be applied to phrases
    // as well by placing them just inside the opening modifier"):
    // `*{color:red}x*` → `<strong style="color:red;">`, `_(big)x_` →
    // `<em class="big">`, and the doubled/long operators, with the same
    // fallbacks as the span forms — malformed runs, whitespace/empty
    // content — plus the em-dash interplay where an unpaired `--` still
    // em-dashes (docs/TEXTILE-PARITY.md §19).
    .{
        .name = "phrase-attr-basic",
        .input = @embedFile("fixtures/textile/phrase-attr-basic.textile"),
        .expected = @embedFile("fixtures/textile/phrase-attr-basic.html"),
    },
    .{
        .name = "phrase-attr-literal",
        .input = @embedFile("fixtures/textile/phrase-attr-literal.textile"),
        .expected = @embedFile("fixtures/textile/phrase-attr-literal.html"),
    },
    // The citation operator `??x??` → `<cite>` (Hobix "Use double
    // question marks to indicate citation"): Hobix's example with the
    // curly-apostrophe replacement, phrase attributes and nesting, and
    // the literal fallbacks — lone `?`, runs of 3+, boundary shapes,
    // malformed/whitespace mods runs, and a no-content run falling back
    // to a plain cite (docs/TEXTILE-PARITY.md §20).
    .{
        .name = "citation-basic",
        .input = @embedFile("fixtures/textile/citation-basic.textile"),
        .expected = @embedFile("fixtures/textile/citation-basic.html"),
    },
    .{
        .name = "citation-literal",
        .input = @embedFile("fixtures/textile/citation-literal.textile"),
        .expected = @embedFile("fixtures/textile/citation-literal.html"),
    },
    // The acronym form `ABC(def)` → `<acronym title="def">ABC</acronym>`
    // (Hobix "Acronyms"): the definition becomes the title, and the
    // literal fallbacks — single letters (`I(think)`), intraword runs,
    // empty/unclosed definitions, and opacity inside `@code@`/link
    // display (docs/TEXTILE-PARITY.md §20).
    .{
        .name = "acronym-basic",
        .input = @embedFile("fixtures/textile/acronym-basic.textile"),
        .expected = @embedFile("fixtures/textile/acronym-basic.html"),
    },
    .{
        .name = "acronym-literal",
        .input = @embedFile("fixtures/textile/acronym-literal.textile"),
        .expected = @embedFile("fixtures/textile/acronym-literal.html"),
    },
    // Definition lists `dl. term:definition` (Textile 2 "Definition
    // lists"): Textile 2's example byte-for-byte with the multi-line
    // definition and hard breaks, `dl<mods>.` attrs on the `<dl>`, term
    // phrases and a colon inside the definition, and the literal
    // fallbacks — a signature without a `term:` prefix, an empty term or
    // definition, an empty signature, and the term-run rule that makes a
    // spaced `see also:` line a continuation (docs/TEXTILE-PARITY.md §21).
    .{
        .name = "dl-basic",
        .input = @embedFile("fixtures/textile/dl-basic.textile"),
        .expected = @embedFile("fixtures/textile/dl-basic.html"),
    },
    .{
        .name = "dl-literal",
        .input = @embedFile("fixtures/textile/dl-literal.textile"),
        .expected = @embedFile("fixtures/textile/dl-literal.html"),
    },
    // The `clear.` marker (Textile 2 "clear"): a lone `clear.`/
    // `clear<.`/`clear>.` line parks a CSS fragment the next block carries
    // in its style attribute — merged ahead of the block's own style —
    // across paragraphs, headings, and lists; the marker line itself
    // renders nothing, and the literal shapes (content after the marker,
    // a word merely starting with "clear", a dangling marker at EOF)
    // stay ordinary text (docs/TEXTILE-PARITY.md §22).
    .{
        .name = "clear-basic",
        .input = @embedFile("fixtures/textile/clear-basic.textile"),
        .expected = @embedFile("fixtures/textile/clear-basic.html"),
    },
    .{
        .name = "clear-literal",
        .input = @embedFile("fixtures/textile/clear-literal.textile"),
        .expected = @embedFile("fixtures/textile/clear-literal.html"),
    },
    // `notextile.`/`notextile..` raw passthrough (current Textile docs
    // "No formatting (override Textile)"; Textile 2 uses `==` instead):
    // the content passes through as one raw `.html_block` — no inline
    // formatting, no replacements, `<em>` stays a real tag — with the
    // single period ending at a blank line and the extended form keeping
    // blank lines until the next block signature; the bare-marker block
    // and the literal shapes (a word merely starting with "notextile",
    // a missing period, mid-paragraph) stay text (docs/TEXTILE-PARITY.md
    // §23).
    .{
        .name = "notextile-basic",
        .input = @embedFile("fixtures/textile/notextile-basic.textile"),
        .expected = @embedFile("fixtures/textile/notextile-basic.html"),
    },
    .{
        .name = "notextile-literal",
        .input = @embedFile("fixtures/textile/notextile-literal.textile"),
        .expected = @embedFile("fixtures/textile/notextile-literal.html"),
    },
    // Inline `==...==` escaping (Textile 2 "Escaping"): phrase delimiters
    // and the character replacements inside the region stay literal, while
    // formatting outside still applies — the current docs' quote example
    // renders its straight quotes byte-for-byte (docs/TEXTILE-PARITY.md §14).
    .{
        .name = "escape-inline",
        .input = @embedFile("fixtures/textile/escape-inline.textile"),
        .expected = @embedFile("fixtures/textile/escape-inline.html"),
    },
    // Textile 2's block-escape example byte-for-byte: the region between
    // the lone `==` lines is not formatted at all — no paragraph wrapper,
    // no em-dash replacement.
    .{
        .name = "escape-block",
        .input = @embedFile("fixtures/textile/escape-block.textile"),
        .expected = @embedFile("fixtures/textile/escape-block.html"),
    },
    // The block escape passes raw HTML through untouched, blank lines
    // inside included, then normal processing resumes.
    .{
        .name = "escape-block-html",
        .input = @embedFile("fixtures/textile/escape-block-html.textile"),
        .expected = @embedFile("fixtures/textile/escape-block-html.html"),
    },
    // Malformed shapes stay literal: an opener not at a boundary, a closer
    // not at a boundary, a `===`+ run, and an unmatched `==`.
    .{
        .name = "escape-literal",
        .input = @embedFile("fixtures/textile/escape-literal.textile"),
        .expected = @embedFile("fixtures/textile/escape-literal.html"),
    },
    // The `|mods|.` line-attribute form applies the full §8 block-modifier
    // set (style/class/id/lang, alignment, padding) to the paragraph,
    // byte-identical to the `p<mods>.` marker (docs/TEXTILE-PARITY.md §15).
    .{
        .name = "line-attr-basic",
        .input = @embedFile("fixtures/textile/line-attr-basic.textile"),
        .expected = @embedFile("fixtures/textile/line-attr-basic.html"),
    },
    // Malformed shapes stay literal: no closing pipe, a dot-terminated run,
    // no period after the pipe, an empty modifier run, empty content, a
    // malformed modifier, a row/cell-only token, and a period not followed
    // by a space.
    .{
        .name = "line-attr-literal",
        .input = @embedFile("fixtures/textile/line-attr-literal.textile"),
        .expected = @embedFile("fixtures/textile/line-attr-literal.html"),
    },
    // The image-modifier battery: all six alignment forms (`<` `>` `=` `-`
    // `^` `~`) fold into the style, and the Textile 2 sizing forms render
    // width/height (docs/TEXTILE-PARITY.md §16).
    .{
        .name = "image-mods-basic",
        .input = @embedFile("fixtures/textile/image-mods-basic.textile"),
        .expected = @embedFile("fixtures/textile/image-mods-basic.html"),
    },
    // Style/class/id modifiers and padding compose through the
    // block-attribute machinery in the pinned order, and an aligned image
    // still links (`!<x!:href`).
    .{
        .name = "image-mods-attrs",
        .input = @embedFile("fixtures/textile/image-mods-attrs.textile"),
        .expected = @embedFile("fixtures/textile/image-mods-attrs.html"),
    },
};

const CooklangFixture = struct {
    name: []const u8,
    input: []const u8,
    expected: []const u8,
};

// Cooklang fixture pairs (docs/COOKLANG.md §Tests, docs/TESTS.md): inputs
// are `.cook` files; expected outputs are the exact bytes of Oliver's own
// deterministic HTML policy (src/cooklang_html.zig).
const cooklang_fixtures = [_]CooklangFixture{
    .{
        .name = "cooklang-basic",
        .input = @embedFile("fixtures/cooklang/cooklang-basic.cook"),
        .expected = @embedFile("fixtures/cooklang/cooklang-basic.html"),
    },
    .{
        .name = "cooklang-sections",
        .input = @embedFile("fixtures/cooklang/cooklang-sections.cook"),
        .expected = @embedFile("fixtures/cooklang/cooklang-sections.html"),
    },
    .{
        .name = "cooklang-frontmatter",
        .input = @embedFile("fixtures/cooklang/cooklang-frontmatter.cook"),
        .expected = @embedFile("fixtures/cooklang/cooklang-frontmatter.html"),
    },
    .{
        .name = "cooklang-literal",
        .input = @embedFile("fixtures/cooklang/cooklang-literal.cook"),
        .expected = @embedFile("fixtures/cooklang/cooklang-literal.html"),
    },
};

// Frontmatter-extension cooklang fixture pair (docs/FRONTMATTER.md §10):
// parsed with `.frontmatter = .yaml` so the parsed metadata view is
// exercised; the raw frontmatter still never renders.
const cooklang_fm_fixtures = [_]CooklangFixture{
    .{
        .name = "frontmatter-cooklang",
        .input = @embedFile("fixtures/cooklang/frontmatter-cooklang.cook"),
        .expected = @embedFile("fixtures/cooklang/frontmatter-cooklang.html"),
    },
};

// Canonical-serialization fixture pairs (docs/COOKLANG.md §10): input
// `.cook` files whose canonical serialization must equal the expected
// `.out.cook` bytes exactly.
const cooklang_serialize_fixtures = [_]CooklangFixture{
    .{
        .name = "serialize-basic",
        .input = @embedFile("fixtures/cooklang/serialize-basic.cook"),
        .expected = @embedFile("fixtures/cooklang/serialize-basic.out.cook"),
    },
    .{
        .name = "serialize-literal",
        .input = @embedFile("fixtures/cooklang/serialize-literal.cook"),
        .expected = @embedFile("fixtures/cooklang/serialize-literal.out.cook"),
    },
};

// Scaling fixture pairs (docs/COOKLANG.md §11): input `.cook` files
// whose canonical scaled serialization must equal the expected
// `.out.cook` bytes exactly.
const CooklangScaleFixture = struct {
    name: []const u8,
    by: oliver.cooklang_scale.ScaleBy,
    input: []const u8,
    expected: []const u8,
};

const cooklang_scale_fixtures = [_]CooklangScaleFixture{
    .{
        .name = "scale-basic",
        .by = .{ .factor = .{ .num = 2, .den = 1 } },
        .input = @embedFile("fixtures/cooklang/scale-basic.cook"),
        .expected = @embedFile("fixtures/cooklang/scale-basic.out.cook"),
    },
    .{
        .name = "scale-servings",
        .by = .{ .servings = 4 },
        .input = @embedFile("fixtures/cooklang/scale-servings.cook"),
        .expected = @embedFile("fixtures/cooklang/scale-servings.out.cook"),
    },
    .{
        .name = "scale-mixed",
        .by = .{ .factor = .{ .num = 2, .den = 1 } },
        .input = @embedFile("fixtures/cooklang/scale-mixed.cook"),
        .expected = @embedFile("fixtures/cooklang/scale-mixed.out.cook"),
    },
};

fn scaleCooklang(input: []const u8, by: oliver.cooklang_scale.ScaleBy) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(std.testing.allocator, input, .{});
    defer result.deinit();
    var scaled = try oliver.cooklang_scale.scaleRecipe(std.testing.allocator, &result.recipe, by);
    defer scaled.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_serialize.serialize(std.testing.allocator, &aw.writer, &scaled, .{});
    return aw.toArrayList();
}

fn checkCooklangScale(name: []const u8, input: []const u8, by: oliver.cooklang_scale.ScaleBy, expected: []const u8) !void {
    var out = try scaleCooklang(input, by);
    defer out.deinit(std.testing.allocator);
    if (!std.mem.eql(u8, expected, out.items)) {
        std.debug.print(
            "cooklang scale fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ name, expected.len, expected, out.items.len, out.items },
        );
        return error.FixtureMismatch;
    }
}

// Menu-view fixture pair (docs/COOKLANG.md §12): a `.menu` file whose
// day/meal text dump must equal the expected `.out.txt` bytes exactly.
const cooklang_menu_fixtures = [_]CooklangFixture{
    .{
        .name = "menu-basic",
        .input = @embedFile("fixtures/cooklang/menu-basic.cook"),
        .expected = @embedFile("fixtures/cooklang/menu-basic.out.txt"),
    },
};

fn menuCooklang(input: []const u8) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(std.testing.allocator, input, .{});
    defer result.deinit();
    var menu = try oliver.cooklang_menu.menuView(std.testing.allocator, &result.recipe);
    defer menu.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_menu.writeMenu(&aw.writer, &menu);
    return aw.toArrayList();
}

fn checkCooklangMenu(name: []const u8, input: []const u8, expected: []const u8) !void {
    var out = try menuCooklang(input);
    defer out.deinit(std.testing.allocator);
    if (!std.mem.eql(u8, expected, out.items)) {
        std.debug.print(
            "cooklang menu fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ name, expected.len, expected, out.items.len, out.items },
        );
        return error.FixtureMismatch;
    }
}

fn serializeCooklang(input: []const u8) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(std.testing.allocator, input, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_serialize.serialize(std.testing.allocator, &aw.writer, &result.recipe, .{});
    return aw.toArrayList();
}

fn checkCooklangSerialize(name: []const u8, input: []const u8, expected: []const u8) !void {
    var out = try serializeCooklang(input);
    defer out.deinit(std.testing.allocator);
    if (!std.mem.eql(u8, expected, out.items)) {
        std.debug.print(
            "cooklang serialize fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ name, expected.len, expected, out.items.len, out.items },
        );
        return error.FixtureMismatch;
    }
}

fn renderCooklangHtml(input: []const u8) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(std.testing.allocator, input, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_html.render(std.testing.allocator, &aw.writer, &result.recipe, .{});
    return aw.toArrayList();
}

fn checkCooklangFixture(name: []const u8, input: []const u8, expected: []const u8) !void {
    var out = try renderCooklangHtml(input);
    defer out.deinit(std.testing.allocator);
    if (!std.mem.eql(u8, expected, out.items)) {
        std.debug.print(
            "cooklang fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ name, expected.len, expected, out.items.len, out.items },
        );
        return error.FixtureMismatch;
    }
}

fn renderHtml(input: []const u8, dialect: oliver.Dialect) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, dialect, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    return aw.toArrayList();
}

fn checkFixture(name: []const u8, dialect: oliver.Dialect, input: []const u8, expected: []const u8) !void {
    var out = try renderHtml(input, dialect);
    defer out.deinit(std.testing.allocator);
    if (!std.mem.eql(u8, expected, out.items)) {
        std.debug.print(
            "fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
            .{ name, expected.len, expected, out.items.len, out.items },
        );
        return error.FixtureMismatch;
    }
}

test "markdown fixtures" {
    for (markdown_fixtures) |f| {
        try checkFixture(f.name, .markdown, f.input, f.expected);
    }
}

fn renderExtHtml(input: []const u8) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .markdown, .{
        .markdown = .{
            .footnotes = true,
            .definition_lists = true,
            .heading_attributes = true,
            .strikethrough = true,
            .wikilinks = true,
            .callouts = true,
            .smartypants = true,
        },
    });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{
        .heading_ids = true,
        .footnotes = true,
    });
    return aw.toArrayList();
}

test "markdown extension fixtures" {
    for (markdown_ext_fixtures) |f| {
        var out = try renderExtHtml(f.input);
        defer out.deinit(std.testing.allocator);
        if (!std.mem.eql(u8, f.expected, out.items)) {
            std.debug.print(
                "extension fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ f.name, f.expected.len, f.expected, out.items.len, out.items },
            );
            return error.FixtureMismatch;
        }
    }
}

fn renderMarkdownFmHtml(input: []const u8, mode: oliver.frontmatter.Option) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .markdown, .{ .frontmatter = mode });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    return aw.toArrayList();
}

test "markdown frontmatter fixtures" {
    for (markdown_fm_fixtures) |f| {
        var out = try renderMarkdownFmHtml(f.input, f.mode);
        defer out.deinit(std.testing.allocator);
        if (!std.mem.eql(u8, f.expected, out.items)) {
            std.debug.print(
                "frontmatter fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ f.name, f.expected.len, f.expected, out.items.len, out.items },
            );
            return error.FixtureMismatch;
        }
    }
}

fn renderTextileFmHtml(input: []const u8) !std.ArrayList(u8) {
    var result = try oliver.parse(std.testing.allocator, input, .textile, .{ .frontmatter = .yaml });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    return aw.toArrayList();
}

test "textile frontmatter fixtures" {
    for (textile_fm_fixtures) |f| {
        var out = try renderTextileFmHtml(f.input);
        defer out.deinit(std.testing.allocator);
        if (!std.mem.eql(u8, f.expected, out.items)) {
            std.debug.print(
                "textile frontmatter fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ f.name, f.expected.len, f.expected, out.items.len, out.items },
            );
            return error.FixtureMismatch;
        }
    }
}

fn renderCooklangFmHtml(input: []const u8) !std.ArrayList(u8) {
    var result = try oliver.cooklang.parse(std.testing.allocator, input, .{ .frontmatter = .yaml });
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.cooklang_html.render(std.testing.allocator, &aw.writer, &result.recipe, .{});
    return aw.toArrayList();
}

test "cooklang frontmatter fixtures" {
    for (cooklang_fm_fixtures) |f| {
        var out = try renderCooklangFmHtml(f.input);
        defer out.deinit(std.testing.allocator);
        if (!std.mem.eql(u8, f.expected, out.items)) {
            std.debug.print(
                "cooklang frontmatter fixture [{s}] mismatch\n--- expected ({d} bytes) ---\n{s}\n--- actual ({d} bytes) ---\n{s}\n",
                .{ f.name, f.expected.len, f.expected, out.items.len, out.items },
            );
            return error.FixtureMismatch;
        }
    }
}

test "textile fixtures" {
    for (textile_fixtures) |f| {
        try checkFixture(f.name, .textile, f.input, f.expected);
    }
}

test "cooklang fixtures" {
    for (cooklang_fixtures) |f| {
        try checkCooklangFixture(f.name, f.input, f.expected);
    }
}

test "cooklang serialize fixtures" {
    for (cooklang_serialize_fixtures) |f| {
        try checkCooklangSerialize(f.name, f.input, f.expected);
    }
    // Round-trip: re-serializing the canonical output is a fixed point.
    for (cooklang_serialize_fixtures) |f| {
        var once = try serializeCooklang(f.input);
        defer once.deinit(std.testing.allocator);
        var twice = try serializeCooklang(once.items);
        defer twice.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, once.items, twice.items);
    }
}

test "cooklang scale fixtures" {
    for (cooklang_scale_fixtures) |f| {
        try checkCooklangScale(f.name, f.input, f.by, f.expected);
    }
    // Scaled output is stable: serializing it again is a fixed point.
    for (cooklang_scale_fixtures) |f| {
        var once = try scaleCooklang(f.input, f.by);
        defer once.deinit(std.testing.allocator);
        var twice = try serializeCooklang(once.items);
        defer twice.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, once.items, twice.items);
    }
}

test "cooklang menu fixtures" {
    for (cooklang_menu_fixtures) |f| {
        try checkCooklangMenu(f.name, f.input, f.expected);
    }
    // Menu text is stable: dumping the view twice is identical.
    for (cooklang_menu_fixtures) |f| {
        var once = try menuCooklang(f.input);
        defer once.deinit(std.testing.allocator);
        var twice = try menuCooklang(f.input);
        defer twice.deinit(std.testing.allocator);
        try std.testing.expectEqualSlices(u8, once.items, twice.items);
    }
}

test "shared model: equivalent inputs render identically through one renderer" {
    // The same normalized structure produced by either dialect must render
    // identically: this is the core convergence claim.
    const pairs = [_]struct { markdown: []const u8, textile: []const u8, expected: []const u8 }{
        .{
            .markdown = "# Hello",
            .textile = "h1. Hello",
            .expected = "<h1>Hello</h1>\n",
        },
        .{
            .markdown = "plain text",
            .textile = "plain text",
            .expected = "<p>plain text</p>\n",
        },
        .{
            .markdown = "## Two\n\nSecond.",
            .textile = "h2. Two\n\nSecond.",
            .expected = "<h2>Two</h2>\n<p>Second.</p>\n",
        },
        .{
            .markdown = "> quote",
            .textile = "bq. quote",
            .expected = "<blockquote>\n<p>quote</p>\n</blockquote>\n",
        },
        // Textile `*x*` (strong) converges with Markdown `**x**`; Textile
        // `_x_` (emphasis) with Markdown `*x_`.
        .{
            .markdown = "**Hello**",
            .textile = "*Hello*",
            .expected = "<p><strong>Hello</strong></p>\n",
        },
        .{
            .markdown = "*Hello*",
            .textile = "_Hello_",
            .expected = "<p><em>Hello</em></p>\n",
        },
        // Textile `"text":url` converges with the Markdown inline link.
        .{
            .markdown = "[x](http://u)",
            .textile = "\"x\":http://u",
            .expected = "<p><a href=\"http://u\">x</a></p>\n",
        },
        // Textile `"text":alias` with a `[alias]url` definition converges
        // with the Markdown reference-link form (same §4.7 machinery).
        .{
            .markdown = "[x][a]\n\n[a]: http://u",
            .textile = "\"x\":a\n\n[a]http://u",
            .expected = "<p><a href=\"http://u\">x</a></p>\n",
        },
        .{
            .markdown = "[x][a]\n\n[a]: http://u \"T\"",
            .textile = "\"x (T)\":a\n\n[a]http://u",
            .expected = "<p><a href=\"http://u\" title=\"T\">x</a></p>\n",
        },
        // Textile `!url!` converges with the Markdown empty-alt image.
        .{
            .markdown = "![](img.png)",
            .textile = "!img.png!",
            .expected = "<p><img src=\"img.png\" alt=\"\" /></p>\n",
        },
        // Textile `*`/`#` lists converge with Markdown lists.
        .{
            .markdown = "* one\n* two",
            .textile = "* one\n* two",
            .expected = "<ul>\n<li>one</li>\n<li>two</li>\n</ul>\n",
        },
        .{
            .markdown = "1. one\n2. two",
            .textile = "# one\n# two",
            .expected = "<ol>\n<li>one</li>\n<li>two</li>\n</ol>\n",
        },
        // Textile `bc.` block code converges with the Markdown fenced code
        // block (same `.code_block` payload, same escaping), including the
        // extended `bc..` form's blank lines.
        .{
            .markdown = "```\na < b\n```",
            .textile = "bc. a < b",
            .expected = "<pre><code>a &lt; b\n</code></pre>\n",
        },
        .{
            .markdown = "```\na\n\nb\n```",
            .textile = "bc.. a\n\nb",
            .expected = "<pre><code>a\n\nb\n</code></pre>\n",
        },
    };
    for (pairs) |p| {
        var from_md = try renderHtml(p.markdown, .markdown);
        defer from_md.deinit(std.testing.allocator);
        var from_tx = try renderHtml(p.textile, .textile);
        defer from_tx.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings(p.expected, from_md.items);
        try std.testing.expectEqualStrings(p.expected, from_tx.items);
    }
}

test "adversarial smoke: hostile input never crashes or leaks" {
    // Cheap stand-ins for fuzzing: pathological punctuation, NUL bytes,
    // mixed line endings, huge delimiter runs. The contract is no crash, no
    // hang, no unbounded recursion, deterministic output.
    const gpa = std.testing.allocator;
    const big = try gpa.alloc(u8, 100_000);
    defer gpa.free(big);
    @memset(big, '#');
    const big_backslashes = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_backslashes);
    @memset(big_backslashes, '\\');

    // 100 KB of `*`: one giant delimiter run through the match/emit phases.
    const big_stars = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_stars);
    @memset(big_stars, '*');

    // Deep open chain "*a *b *c ..." — 10k unclosed opener runs on the
    // delimiter stack; completion proves matching and emission are
    // stack-safe (no recursion) and that openers_bottom keeps it linear.
    var deep_nest = std.ArrayList(u8).empty;
    defer deep_nest.deinit(gpa);
    for (0..10_000) |_| try deep_nest.appendSlice(gpa, "*a ");

    // Alternating `*`/`_` runs: every run intraword-flanks both ways; the
    // mod-3 rule and the shared bottoms table get a hostile workout.
    var alternating = std.ArrayList(u8).empty;
    defer alternating.deinit(gpa);
    for (0..50_000) |_| try alternating.appendSlice(gpa, "*_");

    // 100 KB of backticks: one giant backtick string through the discovery
    // pass (which must stay linear), plus alternated backtick/delimiter runs
    // exercising code-span opacity under stress.
    const big_backticks = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_backticks);
    @memset(big_backticks, '`');
    var backtick_mix = std.ArrayList(u8).empty;
    defer backtick_mix.deinit(gpa);
    for (0..50_000) |_| try backtick_mix.appendSlice(gpa, "`*");

    // 100 KB of `[`: one giant bracket run through link discovery (the
    // bracket stack must not blow up and the splice must stay linear),
    // plus a pathological mix of brackets/links/backticks/delimiters.
    const big_brackets = try gpa.alloc(u8, 100_000);
    defer gpa.free(big_brackets);
    @memset(big_brackets, '[');
    var link_mix = std.ArrayList(u8).empty;
    defer link_mix.deinit(gpa);
    for (0..20_000) |_| try link_mix.appendSlice(gpa, "[a](u) *b* `c` _d_ ");
    var deep_brackets = std.ArrayList(u8).empty;
    defer deep_brackets.deinit(gpa);
    for (0..10_000) |_| try deep_brackets.appendSlice(gpa, "[x]");
    var unbalanced_links = std.ArrayList(u8).empty;
    defer unbalanced_links.deinit(gpa);
    for (0..20_000) |_| try unbalanced_links.appendSlice(gpa, "[a](");

    // Reference-link label bombs: every `]` forces a label scan, case-fold
    // normalization, and map lookup. Shortcut forms must stay linear even
    // when the definitions map is large and labels differ by one codepoint.
    var shortcut_bomb = std.ArrayList(u8).empty;
    defer shortcut_bomb.deinit(gpa);
    for (0..50_000) |_| try shortcut_bomb.appendSlice(gpa, "[alpha] ");
    var shortcut_near_miss = std.ArrayList(u8).empty;
    defer shortcut_near_miss.deinit(gpa);
    for (0..50_000) |_| try shortcut_near_miss.appendSlice(gpa, "[ALPHA!] ");
    var collapsed_bomb = std.ArrayList(u8).empty;
    defer collapsed_bomb.deinit(gpa);
    for (0..30_000) |_| try collapsed_bomb.appendSlice(gpa, "[alpha][] ");
    var failed_inline_bomb = std.ArrayList(u8).empty;
    defer failed_inline_bomb.deinit(gpa);
    for (0..20_000) |_| try failed_inline_bomb.appendSlice(gpa, "[alpha]( ");

    // Definition storms: 20k unique definitions with one-line titles; the
    // definitions map grows, label normalization must stay linear, and
    // first-definition-wins is exercised. Mixed with uses so both the
    // block collection and inline resolution see the full map.
    var def_storm = std.ArrayList(u8).empty;
    defer def_storm.deinit(gpa);
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i < 20_000) : (i += 1) {
        const def = try std.fmt.bufPrint(&buf, "[x{d}]: /url{d} \"t{d}\"\n", .{ i, i, i });
        try def_storm.appendSlice(gpa, def);
        const use = try std.fmt.bufPrint(&buf, "[x{d}] ", .{i});
        try def_storm.appendSlice(gpa, use);
    }
    // One giant label (worst-case normalization scan) plus an unclosed `[`.
    var giant_label = std.ArrayList(u8).empty;
    defer giant_label.deinit(gpa);
    try giant_label.appendSlice(gpa, "[alpha]: /url\n[");
    for (0..200_000) |_| try giant_label.append(gpa, 'a');
    try giant_label.appendSlice(gpa, "]");

    // Block-quote bombs: 100k nested `>` markers (container stack must stay
    // iterative), a lazy-continuation flood inside a quote, and quotes that
    // open and close across blank lines.
    var deep_quotes = std.ArrayList(u8).empty;
    defer deep_quotes.deinit(gpa);
    for (0..100_000) |_| try deep_quotes.append(gpa, '>');
    try deep_quotes.appendSlice(gpa, " x");
    var lazy_flood = std.ArrayList(u8).empty;
    defer lazy_flood.deinit(gpa);
    try lazy_flood.appendSlice(gpa, "> a\n");
    for (0..50_000) |_| try lazy_flood.appendSlice(gpa, "b\n");
    var quote_blanks = std.ArrayList(u8).empty;
    defer quote_blanks.deinit(gpa);
    for (0..50_000) |_| try quote_blanks.appendSlice(gpa, "> a\n\n");
    // Images share the link DoS guards: `![a](` repeated must not make
    // every `]` rescan the whole paragraph (same guard as the `[a](` bomb).
    var unbalanced_images = std.ArrayList(u8).empty;
    defer unbalanced_images.deinit(gpa);
    for (0..20_000) |_| try unbalanced_images.appendSlice(gpa, "![a](");

    // Deep `![` openers on the bracket stack (never closed: literal), and
    // a mixed image/link/delimiter/backtick workload.
    var deep_images = std.ArrayList(u8).empty;
    defer deep_images.deinit(gpa);
    for (0..10_000) |_| try deep_images.appendSlice(gpa, "![");
    var image_mix = std.ArrayList(u8).empty;
    defer image_mix.deinit(gpa);
    for (0..20_000) |_| try image_mix.appendSlice(gpa, "![a](u) *b* `c` ");

    // Reference-image bombs: shortcut/collapsed/full image lookups share
    // the definition map and the monotone inactive check, so repeated
    // `![x]`/`![x][]`/`![x][x]` must stay linear exactly like their link
    // counterparts (docs/REFERENCE-IMAGES.md §4).
    var image_shortcut_bomb = std.ArrayList(u8).empty;
    defer image_shortcut_bomb.deinit(gpa);
    for (0..30_000) |_| try image_shortcut_bomb.appendSlice(gpa, "![alpha] ");
    var image_collapsed_bomb = std.ArrayList(u8).empty;
    defer image_collapsed_bomb.deinit(gpa);
    for (0..20_000) |_| try image_collapsed_bomb.appendSlice(gpa, "![alpha][] ");
    var image_full_bomb = std.ArrayList(u8).empty;
    defer image_full_bomb.deinit(gpa);
    for (0..20_000) |_| try image_full_bomb.appendSlice(gpa, "![alpha][beta] ");
    var image_near_miss = std.ArrayList(u8).empty;
    defer image_near_miss.deinit(gpa);
    for (0..30_000) |_| try image_near_miss.appendSlice(gpa, "![ALPHA!] ");

    // Autolink bombs: repeated URI/email autolinks and near-misses. The
    // recognizer stays linear because `<` and space are forbidden inside
    // the content, so every failed scan is bounded by the next `<` — but
    // a single `<` followed by a huge run of content with no `>` is the
    // worst single scan, so exercise both shapes (docs/AUTOLINKS.md §6).
    var autolink_uri_bomb = std.ArrayList(u8).empty;
    defer autolink_uri_bomb.deinit(gpa);
    for (0..30_000) |_| try autolink_uri_bomb.appendSlice(gpa, "<http://a.com> ");
    var autolink_email_bomb = std.ArrayList(u8).empty;
    defer autolink_email_bomb.deinit(gpa);
    for (0..20_000) |_| try autolink_email_bomb.appendSlice(gpa, "<foo@bar.example.com> ");
    var autolink_near_miss = std.ArrayList(u8).empty;
    defer autolink_near_miss.deinit(gpa);
    for (0..10_000) |_| try autolink_near_miss.appendSlice(gpa, "<ab:abcdefghij ");
    var autolink_huge_content = std.ArrayList(u8).empty;
    defer autolink_huge_content.deinit(gpa);
    try autolink_huge_content.appendSlice(gpa, "<ab:");
    for (0..200_000) |_| try autolink_huge_content.append(gpa, 'a');
    var autolink_mixed = std.ArrayList(u8).empty;
    defer autolink_mixed.deinit(gpa);
    for (0..20_000) |_| try autolink_mixed.appendSlice(gpa, "<http://a.com> [x](u) ![i](v) *em* ");

    // The inactive-bracket marking shape: every `]` forms a link whose
    // opener leaves a dead `[` below on the stack (the monotone check
    // keeps this linear; naive re-marking would be quadratic).
    var nested_link_marks = std.ArrayList(u8).empty;
    defer nested_link_marks.deinit(gpa);
    for (0..5_000) |_| try nested_link_marks.appendSlice(gpa, "[[a](u) ");

    const cases = [_][]const u8{
        "",
        "\n",
        "\n\n\n\n",
        "#",
        "##",
        "### ###",
        "##########",
        "############################## foo ##############################",
        "#5 bolt\n#hashtag\n####### seven",
        "h1.\nh0. x\nh7. y\np.",
        "a\r\nb\rc\nd\r",
        "\x00\x00\x00",
        "a\x00b",
        "# \x00 hidden",
        "a  \nb\\\nc",
        "\\\\x",
        " \n",
        "*\n_\n\n*foo*\n_foo_",
        "*a **b ***c ****d**** e** f* g*",
        "*_*_*\n_*_*_\n",
        big,
        big_backslashes,
        big_stars,
        deep_nest.items,
        alternating.items,
        big_backticks,
        backtick_mix.items,
        big_brackets,
        link_mix.items,
        deep_brackets.items,
        unbalanced_links.items,
        shortcut_bomb.items,
        shortcut_near_miss.items,
        collapsed_bomb.items,
        failed_inline_bomb.items,
        def_storm.items,
        giant_label.items,
        unbalanced_images.items,
        deep_images.items,
        image_mix.items,
        image_shortcut_bomb.items,
        image_collapsed_bomb.items,
        image_full_bomb.items,
        image_near_miss.items,
        autolink_uri_bomb.items,
        autolink_email_bomb.items,
        autolink_near_miss.items,
        autolink_huge_content.items,
        autolink_mixed.items,
        nested_link_marks.items,
        deep_quotes.items,
        lazy_flood.items,
        quote_blanks.items,
    };
    for (cases) |c| {
        inline for ([_]oliver.Dialect{ .markdown, .textile }) |dialect| {
            {
                var result = try oliver.parse(gpa, c, dialect, .{});
                defer result.deinit();
                var aw = std.Io.Writer.Allocating.init(gpa);
                defer aw.deinit();
                try oliver.html.render(gpa, &aw.writer, &result.document, .{});
            }
        }
    }
}

test "adversarial: list workloads are stack-safe and deterministic" {
    const gpa = std.testing.allocator;

    // A compact but deeply nested list: each `- ` opens another item whose
    // first block is a sublist (CommonMark 0.31.2 example 298's shape).
    // This gives thousands of container levels without quadratic indentation.
    var deep_nesting = std.ArrayList(u8).empty;
    defer deep_nesting.deinit(gpa);
    for (0..2_000) |_| try deep_nesting.appendSlice(gpa, "- ");
    try deep_nesting.appendSlice(gpa, "leaf");

    // Large same-marker lists exercise item closing and same-type merging.
    var marker_storm = std.ArrayList(u8).empty;
    defer marker_storm.deinit(gpa);
    for (0..10_000) |_| try marker_storm.appendSlice(gpa, "- item\n");

    // Every marker change must close one list and open another. This is the
    // hostile form of examples 301-302's bullet/delimiter separation rules.
    var alternating_markers = std.ArrayList(u8).empty;
    defer alternating_markers.deinit(gpa);
    for (0..3_000) |_| {
        try alternating_markers.appendSlice(gpa, "- a\n+ b\n* c\n1. d\n1) e\n");
    }

    // Repeated 0-3-space marker indentation must remain a same-level scan,
    // following the boundary exercised by normative example 310.
    var indentation_storm = std.ArrayList(u8).empty;
    defer indentation_storm.deinit(gpa);
    for (0..3_000) |_| {
        try indentation_storm.appendSlice(gpa, "- a\n - b\n  - c\n   - d\n");
    }

    // Nine digits are valid; ten are a near-miss. Run both at volume so an
    // implementation cannot hide repeated integer parsing or rescans.
    var ordered_marker_storm = std.ArrayList(u8).empty;
    defer ordered_marker_storm.deinit(gpa);
    for (0..8_000) |_| try ordered_marker_storm.appendSlice(gpa, "123456789. item\n");
    var ordered_near_miss = std.ArrayList(u8).empty;
    defer ordered_near_miss.deinit(gpa);
    for (0..8_000) |_| try ordered_near_miss.appendSlice(gpa, "1234567890. item\n");

    const cases = [_]struct { name: []const u8, input: []const u8 }{
        .{ .name = "deep nesting", .input = deep_nesting.items },
        .{ .name = "same-marker storm", .input = marker_storm.items },
        .{ .name = "alternating-marker storm", .input = alternating_markers.items },
        .{ .name = "indentation storm", .input = indentation_storm.items },
        .{ .name = "nine-digit ordered-marker storm", .input = ordered_marker_storm.items },
        .{ .name = "ten-digit ordered-marker near-miss", .input = ordered_near_miss.items },
    };
    for (cases) |case| {
        var first = try renderHtml(case.input, .markdown);
        defer first.deinit(gpa);
        var second = try renderHtml(case.input, .markdown);
        defer second.deinit(gpa);
        if (!std.mem.eql(u8, first.items, second.items)) {
            std.debug.print("list adversarial case [{s}] rendered nondeterministically\n", .{case.name});
            return error.NondeterministicRender;
        }
    }
}

test "adversarial: NUL bytes render as U+FFFD" {
    var result = try oliver.parse(std.testing.allocator, "a\x00b", .markdown, .{});
    defer result.deinit();
    var aw = std.Io.Writer.Allocating.init(std.testing.allocator);
    defer aw.deinit();
    try oliver.html.render(std.testing.allocator, &aw.writer, &result.document, .{});
    var out = aw.toArrayList();
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("<p>a\u{FFFD}b</p>\n", out.items);
}

test "adversarial: thematic and Setext leaf storm is deterministic" {
    const gpa = std.testing.allocator;
    var input = std.ArrayList(u8).empty;
    defer input.deinit(gpa);
    for (0..10_000) |_| try input.appendSlice(gpa, "Heading\n---\n* * *\n");

    var first = try renderHtml(input.items, .markdown);
    defer first.deinit(gpa);
    var second = try renderHtml(input.items, .markdown);
    defer second.deinit(gpa);
    try std.testing.expectEqualSlices(u8, first.items, second.items);

    // Every `- ` opens a nested list view, while the final `+ x` makes every
    // suffix a thematic-break near miss. This exercises the path that used to
    // rescan the shrinking suffix at every nesting depth (quadratic); the
    // once-per-line suffix facts make that path linear.
    var deep_near_miss = std.ArrayList(u8).empty;
    defer deep_near_miss.deinit(gpa);
    for (0..20_000) |_| try deep_near_miss.appendSlice(gpa, "- ");
    try deep_near_miss.appendSlice(gpa, "+ x\n");
    var near_miss_out = try renderHtml(deep_near_miss.items, .markdown);
    defer near_miss_out.deinit(gpa);
}

test "adversarial: fenced code scans literal content linearly and deterministically" {
    const gpa = std.testing.allocator;

    // A long opener followed by thousands of almost-long-enough closers must
    // scan each line once; no search/backtracking over accumulated content.
    var near_closers = std.ArrayList(u8).empty;
    defer near_closers.deinit(gpa);
    for (0..64) |_| try near_closers.append(gpa, '`');
    try near_closers.append(gpa, '\n');
    for (0..10_000) |_| {
        for (0..63) |_| try near_closers.append(gpa, '`');
        try near_closers.appendSlice(gpa, " x\n");
    }
    for (0..64) |_| try near_closers.append(gpa, '`');
    try near_closers.append(gpa, '\n');

    // An unclosed block owns all following bytes without attempting to
    // reinterpret inline-looking content at EOF.
    var unclosed = std.ArrayList(u8).empty;
    defer unclosed.deinit(gpa);
    try unclosed.appendSlice(gpa, "~~~ lang\n");
    for (0..20_000) |_| try unclosed.appendSlice(gpa, "*x* <b> & value\n");

    const cases = [_][]const u8{ near_closers.items, unclosed.items };
    for (cases) |input| {
        var first = try renderHtml(input, .markdown);
        defer first.deinit(gpa);
        var second = try renderHtml(input, .markdown);
        defer second.deinit(gpa);
        try std.testing.expectEqualSlices(u8, first.items, second.items);
    }
}

test "diagnostics: fixtures parse without diagnostics" {
    for (markdown_fixtures) |f| {
        var result = try oliver.parse(std.testing.allocator, f.input, .markdown, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    }
    for (textile_fixtures) |f| {
        var result = try oliver.parse(std.testing.allocator, f.input, .textile, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    }
    for (cooklang_fixtures) |f| {
        var result = try oliver.cooklang.parse(std.testing.allocator, f.input, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
    }
}

test "cooklang adversarial: delimiter storms stay bounded and deterministic" {
    const gpa = std.testing.allocator;

    // Huge runs of markers, braces, and comment delimiters; thousands of
    // adjacent ingredients; deep repetition of preparations; an unterminated
    // block comment; a single enormous step; many steps and sections. Each
    // case must parse twice to the same bytes (determinism) without
    // pathological rescanning (the scanner is single-pass per line).
    var at_run = std.ArrayList(u8).empty;
    defer at_run.deinit(gpa);
    for (0..5_000) |_| try at_run.append(gpa, '@');
    try at_run.appendSlice(gpa, "\n");

    var brace_run = std.ArrayList(u8).empty;
    defer brace_run.deinit(gpa);
    for (0..5_000) |_| try brace_run.appendSlice(gpa, "@x{");
    try brace_run.append(gpa, '}');

    var prep_storm = std.ArrayList(u8).empty;
    defer prep_storm.deinit(gpa);
    try prep_storm.appendSlice(gpa, "@x{1}");
    for (0..2_000) |_| try prep_storm.appendSlice(gpa, "(chopped)");

    var unclosed_block = std.ArrayList(u8).empty;
    defer unclosed_block.deinit(gpa);
    try unclosed_block.appendSlice(gpa, "Mix [- never closed\n");
    for (0..10_000) |_| try unclosed_block.appendSlice(gpa, "@flour{1%kg} more\n");

    var many_steps = std.ArrayList(u8).empty;
    defer many_steps.deinit(gpa);
    for (0..5_000) |_| {
        try many_steps.appendSlice(gpa, "Step with @ing{2} and #pot.\n\n");
    }
    try many_steps.appendSlice(gpa, "= Last\n\n");

    var long_line = std.ArrayList(u8).empty;
    defer long_line.deinit(gpa);
    try long_line.append(gpa, '@');
    for (0..100_000) |_| try long_line.append(gpa, 'a');
    try long_line.append(gpa, '\n');

    const cases = [_][]const u8{
        at_run.items,
        brace_run.items,
        prep_storm.items,
        unclosed_block.items,
        many_steps.items,
        long_line.items,
    };
    for (cases) |input| {
        var first = try renderCooklangHtml(input);
        defer first.deinit(gpa);
        var second = try renderCooklangHtml(input);
        defer second.deinit(gpa);
        try std.testing.expectEqualSlices(u8, first.items, second.items);
    }
}
