---
title: "`tools/migration-lab/frontmatter_review.zig` review state"
id: docs/tools/migration-lab/frontmatter_review/review-state
parent: docs/tools/migration-lab/frontmatter_review
status: draft
tags: [boris, zig, tools, review-state, migration-lab, frontmatter_review]
---

# `tools/migration-lab/frontmatter_review.zig` review state

> This page records analytical limitations, unresolved questions, and candidate
> follow-up work. Items listed here are not approved defects, requirements, or
> implementation commitments unless linked to a separately accepted decision.

## Potential follow-up work

### Documentation follow-up

- **`frontmatterreview.json` schema**: No schema document exists. A compact schema table (field names, types, nullable) and a worked example would allow consumers to depend on the format without reading source. — *Need: confirmed; smallest follow-up: add a schema block to a `docs/tools/frontmatter-review.md`; uncertain whether this is currently planned.*
- **Stale-output behavior**: The README (if any) and tool usage output do not mention that files from prior runs in `--out` are not cleaned up when content changes. — *Need: likely; smallest follow-up: add a note to `printUsage` and/or README.*
- **Path safety caveat for absolute `sourceRoot`**: If the caller supplies an absolute path as `--content`, that path appears verbatim in JSON output and varies across machines. Not currently documented. — *Need: uncertain.*


### Test follow-up

- **Two-run byte-for-byte determinism check**: The Notion and Obsidian modules have explicit double-run byte-for-byte JSON comparison tests. The frontmatter-review module does not. — *Observed: missing; why it matters: determinism is claimed structurally but not mechanically confirmed; smallest follow-up: add a fixture test that runs `run` twice and calls `expectEqualStrings(ja, jb)` on both outputs.*
- **Stale output persistence**: A test that plants a file in `--out` before a second run and verifies it survives (to document the gap) or does not survive (to enforce cleanup) would clarify intent. — *Observed: no stale-cleanup test; need: confirmed.*
- **Path safety for `--out` inside `--content` via symlinks**: The string-prefix check does not resolve symlinks. A test analogous to the WordPress symlink escape test would increase confidence. — *Need: likely; uncertain whether this boundary is considered in-scope.*
- **Large file / memory exhaustion**: No test exercises the `.unlimited` allocation path with adversarial input. — *Need: uncertain.*
- **Non-UTF-8 bytes in frontmatter key or value**: Behavior is untested. — *Need: uncertain.*


### Implementation follow-up

- **Markdown heading escaping**: File paths used as H3 headings in `FRONTMATTERREVIEW.md` are not sanitized. A path with `|` or `#` in the name would produce broken Markdown. Passing the path through `escapeMdCell` (or a dedicated heading-escaping function) would close this gap. — *Observed: structural gap; why it matters: malformed Markdown output in adversarial content trees; smallest plausible fix: apply escaping in `emitMd` before the H3 line; need: likely.*
- **JSON escaping completeness**: Control characters U+0001–U+001F outside `\n`, `\r`, `\t`, `\"`, `\\` are emitted verbatim. This violates JSON spec. Since key names from frontmatter are unlikely to contain control characters in practice, the severity is low but the gap is present. — *Observed: structural gap; need: uncertain.*
- **Stale output cleanup on re-run**: Consistent with other migration-lab modes (e.g., WordPress wipes `content/` on re-run), the frontmatter-review mode could delete and recreate `--out` at the start of each run to avoid stale JSON/MD files from a prior content root. — *Observed: gap vs. sibling modules; need: likely.*

***
