# Textile compatibility fixture

Normative behavior is defined by
[`../../textile-compatibility.md`](../../textile-compatibility.md).

- `content/` is a valid Textile-only Trunk/Satellite site.
- `expected/adapted/` pins the in-memory Markdown adapter output.
- `invalid/` contains unsupported and malformed Textile bodies, including a
  conventional table declaration followed by pipe rows.
- `mixed/` proves whole-tree input-format isolation.
