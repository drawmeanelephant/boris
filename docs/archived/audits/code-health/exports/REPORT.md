# Code-health: exports — IR, RAG, context, llms.txt, RSS, sitemap, search

**Card:** #816 — second tranche of #807
**Locus:** `src/ir_emit.zig`, `src/rag.zig`, `src/rag_emit.zig`, `src/context.zig`, `src/llms.zig`, `src/artifact_sink.zig`, `src/rss.zig`, `src/sitemap.zig`, `src/search_index.zig` (+ standalone wrapper `tools/search-index/`)
**Contracts (normative, read first):** `ir-schema.md`, `rag-export.md`, `context-bundle.md`, `llms-txt.md`, `artifact-sink.md`, `rss-2.0.md`, `xml-sitemap.md`, `rendered-search.md`
**Authority:** review only — no product-code changes on this card. Actionable findings were filed as individual issues (#879–#883); fixes land via separate PRs from topic branches targeting `main`.

---

## Environment and gates

| Item | Value |
|---|---|
| Commit | `e1e5da84` (origin/main tip at review start) |
| Zig | 0.16.0 (macOS, darwin) |
| `zig build test` | green before and after review (no product changes made) |
| `zig build test-sitemap` | green |
| `zig build --build-file tools/search-index/build.zig test` | green — 5/5 steps succeeded, 48/48 tests passed (cosmetic stderr noise, FD-4) |
| `./scripts/release-gate.sh` | PASSED |
| Contract fixture check | `docs/contracts/fixtures/rendered-search` golden vs producer: byte-identical (`cmp` clean) |

Fresh worktree of the `main` tip; unrelated worktrees and the sibling audit tree left untouched.

---

## Methodology

Contracts read first, then all nine locus files plus their shared escaping primitives (`json_out.zig`, `encode.zig`, `structured_out.zig`, `site_url.zig`, `rss_date.zig`) and the standalone CLI (`tools/search-index/main.zig`). Drift was checked in both directions (contract → code and code → contract). Every material observation was probed black-box against a purpose-built fixture (UTF-8 entity id, quotes/ampersands/angle brackets in titles and metadata, thematic break, include, wiki-links, RSS posts with equal timestamps, a draft, table + inline code + fenced code) and classified exactly once per the #807 discipline.

---

## Probes (all black-box; commands + results)

### P1 — Determinism (same input twice; clean `dist/` between)

Fixture: 8 pages (trunk/satellites to depth 3, `guides/café.md` UTF-8 id, draft, include, wiki-linked pages, RSS posts) exported under identical flags into two independent directories (`w1`, `w2`), then `rm -rf dist` + rebuild compared against the incremental build (`w3`).

```
boris --input content --out .boris --quiet
boris --input content --quiet
boris --input content --rag --rag-dir rag --quiet
boris --input content --rag --complete --rag-dir rag-complete --quiet
boris --input content --context --context-dir context --quiet
boris --input content --llms --llms-path llms.txt --quiet
boris --input content --rss --site-url 'https://docs.example/docs&guides/' --rss-title 'Feed & Stuff <t>' --rss-description 'Updates "here"' --quiet
boris --input content --sitemap --site-url 'https://docs.example/docs&guides/' --quiet
diff -r w1/<tree> w2/<tree>   # for dist, rag, rag-complete, context, .boris
cmp w1/llms.txt w2/llms.txt; cmp w1/rss.xml w2/rss.xml
```

Result: **identical** for every surface (`diff -r` clean; `cmp` clean), including `dist/` (HTML + `_boris/search/search-index.json` + `sitemap.xml`) and clean-vs-incremental. The failure path was exercised incidentally (invalid fixture build): only `build-report.json` written, prior `manifest.json`/`graph.json`/`completion.json` removed — matches `ir-schema.md:62-68`. Worktree-state independence: IR carries no VCS token (#781 decision); only complete-mode `catalog_meta.json` carries the baked `vcs_revision` (`"e1e5da84"` with this binary), which is attribution, not nondeterminism.

### P2 — Search tokenization (#778, closed; falsified recurrence)

Input page: prose around `code` spans, two successive spans, fenced block, table with `<td>`/`<th>`, entities. Built index excerpt (`dist/_boris/search/search-index.json`):

```
text: 'Before-code prose mid-prose, then more words.'
code: 'cat <file> & more grep -r "pattern" ./dir'
text: 'Key arm64 & x86 Nav word tail words end words.'
code: 'otool -L strings'
```

- Successive code fragments joined by a single U+0020 (`otool -L strings`, not `otool -Lstrings`) — matches `rendered-search.md:120-124`.
- Prose gains a word boundary at inline-code edges (no fused `wordtail` token); code stays out of `text`.
- Contract golden: `boris-search-index --root=docs/contracts/fixtures/rendered-search/site --out=/tmp/boris-rendered-search-contract` + `cmp` against the expected artifact → **identical**.

### P3 — RSS / sitemap edges

`xmllint --noout` on both `rss.xml` and `dist/sitemap.xml` → **valid**.

- Escaping: `Feed &amp; Stuff &lt;t&gt;`, channel link `https://docs.example/docs&amp;guides` (trailing slash normalized, base ampersand escaped).
- Dates: `pubDate` `Sat, 01 Aug 2026 10:00:00 GMT` — RFC-822 GMT; weekday cross-checked against an independent calendar (Python `datetime` → `Sat`); `rss_date.zig` unit tests pin the strict `YYYY-MM-DDTHH:MM:SSZ` grammar and invalid forms.
- Sorting/tie-break: `posts/a` before `posts/z` at identical timestamps (canonical id ascending); limit applied after sort; draft excluded despite a newer timestamp.
- URL joining/encoding: one-slash join; `guides/café.html` → `caf%C3%A9.html` (uppercase hex) in sitemap and llms; contract example reproduced.
- CLI rejects (all exit 2): bad scheme, spaced/trailing-space URL, `--rss-limit 0` / `501` / `abc`, missing required RSS settings, `--rss` + `--complete` conflict.

### P4 — Standalone vs in-build (#750 pattern; #750 closed, pruning verified)

```
boris-search-index --root dist --out /tmp/…/search                 # discovery mode
boris-search-index --root dist --out /tmp/…/search --pages-file …  # compiler-owned list
```

- `_boris/proof/*` chrome and the search artifact are **not indexed** by discovery (the #750 defect stays fixed; unit tests `main.zig:331-365` pin it).
- With `--pages-file` carrying the compiler-owned page list, standalone output is **byte-identical** to the in-build artifact.
- Discovery-only mode indexes an emitted `draft.html` that the in-build producer excludes — see the documented limitation below.

---

## Falsification table

| # | Probe / observation | Locus | Contract | Code / test citation | Result |
|---|---|---|---|---|---|
| 1 | Determinism, all seven export surfaces, two runs + clean-vs-incremental | all locus files | `ir-schema.md:247-286`, `rag-export.md:344-382` | stable sorts at `ir_emit.zig:411-417`, `rag.zig:404-408`, `rag_emit.zig:47-53`, `sitemap.zig:106`, `search_index.zig:432-436`; byte-identity tests `rag.zig:1674-1706,1816-1826`, `llms.zig:340-372`, `search_index.zig:712-723` | **Identical** (P1) |
| 2 | IR key orders, sorted pages/edges/reverseIndex/nav, staging + failure policy | `ir_emit.zig` | `ir-schema.md` key-order and edge sections | key orders match contract lists (`ir_emit.zig:63-121,235-442,614-703`); failure path observed in P1; `artifact_sink.zig:128-178` stage+rename | Match |
| 3 | RAG manifest field order / catalog field order / catalog_meta shape | `rag_emit.zig:186-247,393-436` | `rag-export.md:193-217,385-410,219-240` | byte-for-byte field order match; `catalog_meta.json` = `{"format","schema_version":2,"boris_version","vcs_revision"}` + LF (`rag.zig:1117-1172` tests) | Match |
| 4 | Working-mode isolation: no system seeds, no catalog_meta; SeparatorCollision; header not counted; verbatim fidelity | `rag.zig:561-701` | `rag-export.md:104-107,119-201` | tests `rag.zig:1400-1473,1600-1635`; marker collision rejected `rag.zig:490-492` | Match |
| 5 | Context bundle: provenance sha256 true, dynamic fence, graph_scope full, YAML line-terminator quoting | `context.zig` | `context-bundle.md` | manifest sha256 vs actual bytes verified black-box; fence `context.zig:143-147`; `graph_scope: "full"` always (`context.zig:331`, test `context.zig:575-607`); U+2028/2029/0085 handled (`context.zig:113-127`) | Match |
| 6 | llms.txt: fixed header, id-order recursion, `.html` URL fallback + percent-encoding, punctuation escaping, 240-byte UTF-8 truncation | `llms.zig` | `llms-txt.md:20-60` | tests `llms.zig:283-338,374-452`; escaping `llms.zig:62-71` | Match, except FD-1 |
| 7 | RSS: strict timestamps, eligibility, desc sort + id tie, limit 1–500, XML escaping, permalink GUID, categories in source order, no wall clock | `rss.zig`, `rss_date.zig` | `rss-2.0.md` | `rss.zig:92-157`; `rss_date.zig` tests; XML valid via xmllint (P3) | Match |
| 8 | Sitemap: path grammar, owned-namespace collisions, URL validation, percent-encoding, sort + duplicate failure, 50k/50MiB limits without truncation, overlay existence check, atomic publish | `sitemap.zig` | `xml-sitemap.md` | tests `sitemap.zig:201-283`; limits `sitemap.zig:92,121-124`; overlay `sitemap.zig:176-199` | Match |
| 9 | Search: #778 word boundaries, single JSON escaper with control chars, entity decode, table/br separators, path sort, empty-site artifact, staged>live overlay read | `search_index.zig` | `rendered-search.md` | tests `search_index.zig:473-758`; #778 fix `search_index.zig:279-300`; golden cmp (P2) | Match |
| 10 | Artifact sink: path rules, duplicate rejection, Dir stage+rename, failure emits build-report only | `artifact_sink.zig` | `artifact-sink.md` | tests `artifact_sink.zig:200-221`; failure policy `artifact_sink.zig:135-145` | Match |
| 11 | Thematic break becomes llms description | `llms.zig:96-125` | `llms-txt.md:54-56` | black-box P-finding (`[Deep Notes](/guides/deep.html): ---`) | **Drift → FD-1 / #879** |
| 12 | `--site-url` rejection blamed on `--input` | `cli.zig:1982-1988` (+ `2555-2564`) | usage-error diagnostics; #761 rule at `cli.zig:2569-2573` | black-box: `error: invalid value for --input` for RSS and sitemap | **Drift → FD-2 / #880** |
| 13 | Undocumented `data-boris-search-title` extraction marker | `search_index.zig:275,292` | `rendered-search.md:100-112` lists markers; this one absent | repo-wide grep: only occurrence | **Drift → FD-3 / #881** |
| 14 | Green focused gate prints `failed command` | `tools/search-index/build.zig:14-22` | `rendered-search.md:177-186` names the gate | stderr capture + `--summary all` (5/5 steps, 48/48 tests) | **Drift → FD-4 / #882** |
| 15 | Wiki-link targets ASCII-only vs UTF-8 entity ids (out-of-locus) | `wikilink.zig:128-133` | `identity-and-paths.md:71,124`; `includes-and-wiki-links.md:52` | black-box `EREFERENCESYNTAX` on `[[guides/café]]` | **Drift → FD-5 / #883** |
| 16 | Standalone discovery indexes emitted draft pages the in-build set excludes | `tools/search-index/main.zig:254-270` | `html-output.md:190-199` (drafts emitted, unlisted; search excludes drafts in-build) | P4 discovery vs pages-file | **Documented limitation** (contract-absorbed; `--pages-file` is the exact-list path) |
| 17 | #778 / #750 recurrence | `search_index.zig:279-300`, `tools/search-index/main.zig:196,262,334` | — | P2 golden + output; P4 pruning | **Both stay fixed** (probes falsified recurrence) |

---

## Findings

| # | Finding | Severity | Classification | Issue |
|---|---|---|---|---|
| FD-1 | llms.txt description can be a thematic break (`---`) instead of the first paragraph | Low | Confirmed defect | [#879](https://github.com/drawmeanelephant/boris/issues/879) |
| FD-2 | CLI blames `--input` for `--site-url` validation failures (RSS/sitemap, exit 2 correct) | Low | Confirmed defect | [#880](https://github.com/drawmeanelephant/boris/issues/880) |
| FD-3 | Undocumented `data-boris-search-title` producer extraction marker | Low | Likely defect | [#881](https://github.com/drawmeanelephant/boris/issues/881) |
| FD-4 | Contracted focused gate prints `failed command` on a green run (48/48 pass, exit 0) | Low | Confirmed defect (observable; mechanism suspected, untraced) | [#882](https://github.com/drawmeanelephant/boris/issues/882) |
| FD-5 | Wiki-link target grammar ASCII-only vs normative UTF-8 entity ids (out-of-locus discovery) | Low | Likely defect | [#883](https://github.com/drawmeanelephant/boris/issues/883) |

Documented limitation (no issue): standalone search-index discovery mode indexes emitted draft pages that the compiler-owned live set excludes. `html-output.md:190-199` contracts draft HTML as emitted-but-unlisted, and the standalone producer is contracted to consume final HTML only (`rendered-search.md:7-12`); the exact compiler-owned list is available via `--pages-file`, which produced byte-identical output (P4). Residual risk: a discovery-mode index over a draft-bearing target advertises draft pages until a pages-file is supplied.

Findings feed the open Source-RAG publication-safety item by reference only; scope was not expanded.

---

## Verified clean (summary)

IR schema/key orders/sorting/staging; RAG working packs (isolation, verbatim fidelity, marker-collision fail-closed, packing rules, sidecar field order) and complete corpus (catalog self-consistency, catalog_meta shape, publish-restore); Context Bundle (provenance hashes byte-true, fence sizing, YAML line-terminator escaping, scoped full-graph marking); llms.txt (ordering, URL fallback, escaping, 240-byte truncation); RSS (dates, sort/tie-break, limits, escaping, publication-location checks); sitemap (path grammar, collisions, percent-encoding, limits, overlay verification); rendered search (#778 fixed, contract golden byte-identical, #750 pruning fixed, fail-closed malformed inputs, empty-site artifact); artifact sink (path rules, duplicates, stage+rename, failure policy).

**Determinism is the load-bearing result:** every export surface produced byte-identical trees across independent runs, separate directories, and clean-vs-incremental builds on the same host — the property the #776 evidence digest chain depends on.
