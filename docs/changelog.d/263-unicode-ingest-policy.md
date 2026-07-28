### Security

- Content source is now checked for invisible and non-interchange Unicode at
  ingest, in [`src/unicode_policy.zig`](/src/unicode_policy.zig), because these
  code points reach every output unchanged and none of them are HTML-special —
  an escaper cannot see them. Controls, Unicode noncharacters, deprecated
  format controls, interlinear annotations, bidi embeddings and overrides
  (U+202A–U+202E), unclosed bidi isolates, an interior U+FEFF, and tag
  characters outside an emoji subdivision-flag sequence are refused with a new
  `EUNICODE` diagnostic naming the file, line and column
  ([contract](/docs/contracts/diagnostics.md)). Characters that are invisible
  but genuinely load-bearing — ZWJ, ZWNJ, ZWSP, word joiner, soft hyphen — are
  never rewritten; a smuggling *shape* (a run of three or more, or interleaving
  between ASCII letters) is reported at warning severity instead. Emoji ZWJ
  sequences, subdivision flags such as the Scotland flag, Persian and Indic
  orthography, CJK, RTL scripts and combining marks all keep building
  unchanged, covered by [`fixtures/hostile-output/`](/fixtures/hostile-output/).
