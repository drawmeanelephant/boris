# Fixture: malformed frontmatter

**Expect:** exit `1`, at least one `EFRONTMATTER`.

## Cases in tree

| File | Issue |
|------|--------|
| `content/unknown-key.md` | illegal key `tags` |
| `content/unclosed.md` | opening `---` without closing fence |
| `content/bad-line.md` | line without `:` |

Any one of these is sufficient to fail the compile. Implementations should
report **all** discoverable frontmatter errors when cheap to do so.

## Sample expected stderr (unknown key)

```text
error: EFRONTMATTER: unknown-key.md:3:1: unknown key "tags"
```

## Sample expected stderr (unclosed)

```text
error: EFRONTMATTER: unclosed.md:1:1: unclosed frontmatter
```
