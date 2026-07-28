### Security

- The rendered search index no longer ships invalid JSON. `writeJson` in
  [`src/search_index.zig`](/src/search_index.zig) escaped quotes, backslashes
  and the three whitespace escapes but not the remaining C0 control
  characters, so a single control byte in any page's text emitted a bare
  control code inside a JSON string. `search-index.json` then failed to parse
  and client search went dead for the whole site, not just that page. The
  escaper was a hand-copied variant of
  [`src/json_out.zig`](/src/json_out.zig)'s with one branch missing; it now
  delegates there, and a regression test parses the emitted index with
  `std.json`.
