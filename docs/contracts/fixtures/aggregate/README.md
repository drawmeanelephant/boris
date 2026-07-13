# Fixture: aggregate independent diagnostics

**Expect:** exit `1`, **multiple** diagnostics in one run
(`E_PARENT_MISSING`, `E_PARENT_SELF`, `E_FRONTMATTER`) — proves we do not
fail at the first error only.
