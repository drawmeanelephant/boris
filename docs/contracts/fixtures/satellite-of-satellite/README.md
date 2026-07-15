# Fixture: satellite-of-satellite (multi-hop)

**Expect:** exit `1`, `EPARENTNOTTRUNK`.

## Layout

```text
content/
  trunk.md   # trunk (no parent)
  mid.md     # parent: trunk  (satellite)
  leaf.md    # parent: mid    (satellite-of-satellite — hard error)
```

v0.1 is one-level Trunk → Satellite only. Nested parent chains fail hard.
