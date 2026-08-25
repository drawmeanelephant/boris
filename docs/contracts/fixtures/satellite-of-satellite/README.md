# Fixture: satellite-of-satellite (multi-hop)

**Expect:** exit `0`; this is a valid multi-level hierarchy.

## Layout

```text
content/
  trunk.md   # trunk (no parent)
  mid.md     # parent: trunk  (satellite)
  leaf.md    # parent: mid    (third level)
  great-grandchild.md # parent: leaf (fourth level)
```

Every non-root page is a Satellite of its immediate parent, while the complete
root/child/grandchild/great-grandchild chain proves that validated parent chains
may be nested to represent a real documentation hierarchy.
