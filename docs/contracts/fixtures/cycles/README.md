# Fixture: parent cycle

**Expect:** exit `1`, `E_PARENT_CYCLE`.

## Layout

```text
content/
  a.md    # parent: b
  b.md    # parent: a
```

Cycle: `a → b → a`.

## Expected diagnostic (minimum)

At least one error of the form:

```text
error: E_PARENT_CYCLE: a.md:3:1: parent cycle involving a -> b -> a
```

or equivalent that lists both ids in stable sorted order, e.g.
`a -> b -> a` (start at lexicographically smallest id in the cycle).

## Notes

- Both files also have valid frontmatter grammar; failure is graph-only.
- Self-parent is a separate code (`E_PARENT_SELF`); this fixture is a
  two-node cycle.
