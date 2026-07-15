# Fixture: longer parent cycle (3 nodes)

**Expect:** exit `1`, `EPARENTCYCLE`.

## Layout

```text
content/
  a.md    # parent: b
  b.md    # parent: c
  c.md    # parent: a
```

Cycle: `a → b → c → a`.

## Expected diagnostic (minimum)

At least one error naming every id in the cycle in stable sorted order, e.g.
`a -> b -> c -> a`.
