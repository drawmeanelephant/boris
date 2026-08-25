# Astro initial-create apply fixture

This committed synthetic fixture is the public CLI proof for Slice B1. It has
two supported plain-Markdown inputs with different closed-frontmatter shapes,
including one without an authored `id`, nested source directories, a quarantined
MDX-like source, and an unsupported source. It is never executed.

The fixture-backed newline policy is **LF-only source files**. The public CLI
test verifies the body bytes exactly, including the fixture's LF line endings;
the apply renderer's separate unit test covers CRLF body preservation.
