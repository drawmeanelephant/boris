# Fixture: case-only entity id collision

**Expect:** exit `1`, `EINVALIDPATH`.

Two files override `id:` to values that differ only in letter case
(`guides/intro` vs `GUIDES/INTRO`). Discovery case checks cover path-derived
ids; this fixture asserts the same rule on **final resolved** ids in
`graph.diagnoseDuplicateIds`.
