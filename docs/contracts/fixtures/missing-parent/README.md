# Fixture: missing parent

**Expect:** exit `1`, `EPARENTMISSING`.

## Layout

```text
content/
  orphan.md    # parent: does-not-exist
```

No page has id `does-not-exist`.

## Expected diagnostic

```text
error: EPARENTMISSING: orphan.md:3:1: parent "does-not-exist" does not exist
```

(Exact column may be `1` if the implementation anchors at line start.)
