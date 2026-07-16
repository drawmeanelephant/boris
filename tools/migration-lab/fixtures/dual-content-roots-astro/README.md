# dual-content-roots-astro fixture

Both `src/content/` and root-level `content/` exist. Archaeology inventories
Markdown under each supported root and emits an `ambiguous_content_roots`
human-review hazard. Arbitrary repository Markdown outside those roots is ignored.
