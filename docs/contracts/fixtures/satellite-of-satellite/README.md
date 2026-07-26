# Fixture: satellite-of-satellite (multi-hop)

**Expect:** exit `0`; this is a valid multi-level hierarchy.

## Layout

```text
content/
  trunk.md   # trunk (no parent)
  mid.md     # parent: trunk  (satellite)
  leaf.md    # parent: mid    (third level)
```

Every direct edge remains Trunk/Satellite-shaped, while validated parent chains
may be nested to represent a real documentation hierarchy.
