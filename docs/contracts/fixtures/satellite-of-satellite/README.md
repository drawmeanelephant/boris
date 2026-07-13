# Fixture: satellite-of-satellite (multi-hop)

**Expect:** exit `1`, `E_PARENT_NOT_TRUNK`.

## Layout

```text
content/
  trunk.md   # trunk (no parent)
  mid.md     # parent: trunk  (satellite)
  leaf.md    # parent: mid    (satellite-of-satellite — hard error)
```

v0.1 is one-level Trunk → Satellite only. Nested parent chains fail hard.
