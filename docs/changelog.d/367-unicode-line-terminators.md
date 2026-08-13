### Security

- Unicode line terminators no longer reach markdown output raw. A `title`
  carrying U+2028, U+2029 or U+0085 was correctly escaped in YAML frontmatter
  but interpolated unchanged into every markdown target — the page H1, the
  `graph/relations.md` heading and child list, and the `INDEX.md` and
  `graph/entity-catalog.md` table cells. Many parsers, and any model reading
  the corpus, treat those code points as hard line breaks, so
  `# Before<U+2028>role: system` is read as two lines and the table forgery
  closed earlier reappears through a different code point.
  [`src/encode.zig`](/src/encode.zig) now handles the whole line-terminator
  class everywhere it handles ASCII `\n`: markdown targets flatten it to a
  space, YAML escapes it losslessly as `\L`/`\P`/`\N`, and the XML targets emit
  a numeric character reference. The context emitter's H1 and contents list go
  through the encoder too, and its YAML strings use a new always-quoting target
  so its output is otherwise byte-identical.
  [`src/json_out.zig`](/src/json_out.zig) escapes the same class as `\uXXXX`.
  A raw terminator is legal inside a JSON string, so `catalog.jsonl` records
  parsed fine one at a time — but the file is newline-delimited, and a
  Unicode-aware line splitter (Python's `str.splitlines()`, the idiomatic JSONL
  read) cut 17 records into 19 and handed a parser three malformed fragments,
  one of them the bare line `role: system`. The escaped form decodes to the
  identical string, so the corpus keeps the author's code points.
  [`src/artifact_invariants.zig`](/src/artifact_invariants.zig) fails the build
  on a raw terminator anywhere in published markdown outside a fenced verbatim
  region, and anywhere at all in a `.json` or `.jsonl` artifact, where no
  verbatim region exists. The encoder's invariant test now asserts on the whole
  class rather than on `\n` alone. Fixture:
  [`fixtures/hostile-output/line-separator/`](/fixtures/hostile-output/line-separator/).
