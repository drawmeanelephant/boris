# Hostile output fixtures

Content trees whose **frontmatter values are shaped to break out of the
container the emitters write them into**. They exist to be compiled, not read:
`src/emitter_hostile_test.zig` runs every tree here through the RAG and context
emitters and asserts that every published artifact still satisfies
`src/artifact_invariants.zig`.

Each subdirectory is one tree with a `content/` root. Adding a tree needs no
code change — the test walks this directory.

| Tree | What it shapes |
|------|----------------|
| `yaml-breakout/` | A `tags` item that closes the flow sequence and appends top-level keys |
| `table-breakout/` | A `title` carrying `\|` so it forges columns in the catalog tables |
| `unicode-smuggling/` | Invisible code points — a tag-block payload and a bidi override. Carries `REJECT-AT-INGEST`: this tree must **fail** to compile with `EUNICODE`, not publish safely. |
| `legitimate-punctuation/` | Real authoring that merely *looks* hostile — CJK, emoji, RTL, an inline `\|`, a colon, backticks, plus the invisible-but-load-bearing cases: a subdivision flag, an emoji ZWJ sequence, a Persian ZWNJ, a balanced bidi isolate. Must keep compiling and must not be mangled. |

The last tree is not decoration. A security fix that makes ordinary
documentation unwritable is a product regression, and this is where that shows
up as a failing test rather than as a user complaint.
