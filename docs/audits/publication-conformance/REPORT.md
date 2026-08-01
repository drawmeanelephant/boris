# Publication conformance evidence: C02, C03, C04, and C08

Date: 2026-08-01
Base: `afterparty` at `7cebfa80c325827a1e726aca630c31b013788257`
Evidence branch: `codex/publication-conformance-fixtures`

## Authority and scope

This is an evidence-and-fixture pass for the requested publication-conformance
areas. The normative authorities were, in order, the relevant contracts under
`docs/contracts/`, the current executable implementation, the focused tests,
and these retained black-box fixtures. No shared `CHANGELOG.md` section,
publication-check harness, benchmark, worker-control code, or test-data
generator was changed. The only product-tree code change is focused parser test
coverage; no production implementation behavior was changed.

The material-observation labels below are deliberately limited to the required
set: `Confirmed defect`, `Likely defect`, `Insufficient evidence`, `Documented
limitation`, and `Non-issue / packet drift`.

The C02/C03/C04/C08 source trees and expected outputs are retained under this
directory. The referenced repository invalid-UTF-8 fixture remains in its
existing `fixtures/` location. Fresh generated outputs and stream captures
live under the ignored `.zig-cache/conformance/` tree and are not merge
artifacts.

## Fixture index

| Area | Retained fixture root | Primary evidence |
|---|---|---|
| C02 includes and fragments | [`c02-includes-fragments`](c02-includes-fragments) | HTML goldens, exact diagnostics, include-depth boundary |
| C03 sitemap | [`c03-sitemap`](c03-sitemap) | `meta/discovery.xml`, nested paths, draft and asset exclusions |
| C04 RSS 2.0 | [`c04-rss`](c04-rss) | limit 2/3/4 feeds, XML escaping, content/config failures |
| C08 parser and Unicode | [`c08-parser-unicode`](c08-parser-unicode) | Unicode IR golden, BOM/malformed cases, parser boundary tests |

## Method and stream handling

Commands were run from the repository root of the isolated worktree. Success
cases used `--quiet` where the output artifact was the assertion; their stdout
and stderr were zero bytes. Non-quiet failure transcripts were captured as
separate streams. Boris writes its progress and diagnostics to stderr; the
checked-in failure snapshots preserve that exact stream, including the
progress lines where present.

The source-byte spot checks were:

```text
xxd -g 1 -l 24 docs/audits/publication-conformance/c08-parser-unicode/cases/bom/content/bom.md
00000000: ef bb bf 2d 2d 2d 0a 74 69 74 6c 65 3a 20 42 4f  ...---.title: BO
00000010: 4d 20 72 65 6a 65 63 74                          M reject

xxd -g 1 fixtures/content/invalid/invalid-utf8.md
...
00000020: 0a 0a 62 61 64 3a 20 ff 20 6d 6f 72 65 0a        ..bad: . more.
```

The retained BOM bytes are `EF BB BF` at byte zero. The retained invalid-UTF-8
fixture contains a literal `FF` byte at offset `0x27`; the new parser test also
uses the truncated byte sequence `E2 82` so both invalid-byte shapes are
covered.

## C02 — includes and heading fragments

### Exact commands and results

The success commands below exited `0`; `--quiet` produced empty stdout and
stderr. Each output was compared with its checked-in expected HTML using
`cmp`.

```text
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/01-include-success/content --html-dir .zig-cache/conformance/c02/01-include-success --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html --quiet
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/05-valid-fragment/content --html-dir .zig-cache/conformance/c02/05-valid-fragment --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html --quiet
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/07-fragment-after-include/content --html-dir .zig-cache/conformance/c02/07-fragment-after-include --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html --quiet
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/08-duplicate-heading/content --html-dir .zig-cache/conformance/c02/08-duplicate-heading --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html --quiet
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/09-nested-include-path/content --html-dir .zig-cache/conformance/c02/09-nested-include-path --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html --quiet
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/10-depth-32/content --html-dir .zig-cache/conformance/c02/10-depth-32 --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html --quiet
```

The checked-in HTML goldens matched byte-for-byte. The retained observations
are:

- `01-include-success`: included bytes render between the surrounding body
  paragraphs.
- `05-valid-fragment`: `target#ordinary-section` resolves to the target page
  and rendered heading id.
- `07-fragment-after-include`: a heading introduced by an include participates
  in the same-page heading index and resolves from the later wiki-link.
- `08-duplicate-heading`: both `id="duplicate"` headings remain in the target
  output and the link uses the allowed exact-id set membership; no accidental
  de-duplication was observed.
- `09-nested-include-path`: nested relative include resolution preserves both
  outer and inner bytes.
- `10-depth-32`: the documented depth boundary succeeds and renders the
  boundary marker.

Representative successful target listing (`01-include-success`) was:

```text
.zig-cache/conformance/c02/01-include-success/_boris/proof/artifacts.json
.zig-cache/conformance/c02/01-include-success/_boris/search/search-index.json
.zig-cache/conformance/c02/01-include-success/index.html
```

The negative commands exited `1`. Their stdout files were all zero bytes, and
each stderr file matched the checked-in snapshot with `cmp`:

```text
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/02-missing-include/content --html-dir .zig-cache/conformance/c02/02-missing-include-stream-output --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/03-direct-cycle/content --html-dir .zig-cache/conformance/c02/03-direct-cycle-stream-output --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/04-long-cycle/content --html-dir .zig-cache/conformance/c02/04-long-cycle-stream-output --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/06-missing-fragment/content --html-dir .zig-cache/conformance/c02/06-missing-fragment-stream-output --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c02-includes-fragments/cases/11-depth-33/content --html-dir .zig-cache/conformance/c02/11-depth-33-stream-output --html-layout docs/audits/publication-conformance/c02-includes-fragments/layout.html
```

Expected stderr, retained beside each case, was:

```text
EINCLUDEMISSING: index.md:4:1: include target "includes/missing.md" not found or unreadable
EINCLUDECYCLE: includes/a.md:1:1: include cycle involving "includes/a.md"
EINCLUDECYCLE: includes/c.md:1:1: include cycle involving "includes/a.md"
EREFERENCEMISSING: index.md:4:5: wiki-link heading target "target#does-not-exist" not found on the page
EINCLUDECYCLE: includes/level-32.md:1:1: include nesting depth exceeded
```

The bracketed remediation text and full structured lines are retained in the
five `expected/stderr.txt` files. No failing case created a final HTML output
root.

### C02 classification

- `10-depth-32` success and `11-depth-33` rejection are a **Non-issue /
  packet drift** if a contrary claim says the boundary is missing: the
  executable behavior and exact diagnostics match the include contract.
- The code also contains `max_expanded_bytes = 16 MiB` and
  `max_include_expansions = 4096` in `src/include.zig`, but the reviewed
  contract does not normatively own numeric values for those two budgets. That
  is **Insufficient evidence**, not a product defect. The smallest follow-up
  is to give those budgets an explicit contract owner and add one fixture per
  boundary before claiming conformance.
- Included Markdown is covered; arbitrary post-render HTML fragments are not
  covered by this C02 pass. That is an explicit scope gap, not a failure.

## C03 — XML sitemap

### Exact commands and results

```text
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c03-sitemap/content --html-dir .zig-cache/conformance/c03/trailing --html-layout docs/audits/publication-conformance/c03-sitemap/layout.html --sitemap-path meta/discovery.xml --site-url 'https://docs.example/docs&guides/' --quiet
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c03-sitemap/content --html-dir .zig-cache/conformance/c03/no-trailing --html-layout docs/audits/publication-conformance/c03-sitemap/layout.html --sitemap-path meta/discovery.xml --site-url 'https://docs.example/docs&guides' --quiet
```

Both commands exited `0`, and the two sitemap files have identical SHA-256:

```text
9d2e11edc5c200b8c17ed1e65d822fa3c064150040bf838805b7b9c0c06dc93f
```

The expected sitemap contains exactly four `<loc>` elements, in deterministic
absolute-URL order:

```xml
<url><loc>https://docs.example/docs&amp;guides/caf%C3%A9.html</loc></url>
<url><loc>https://docs.example/docs&amp;guides/guides.html</loc></url>
<url><loc>https://docs.example/docs&amp;guides/guides/install.html</loc></url>
<url><loc>https://docs.example/docs&amp;guides/index.html</loc></url>
```

The generated target listing also contained `draft.html` and the copied
`guides.assets/notes.txt`; those are correctly absent from the sitemap. This
demonstrates page eligibility is not a directory crawl and that a draft HTML
page does not become a sitemap URL.

The complete trailing-slash target listing was:

```text
.zig-cache/conformance/c03/trailing/.boris-cache/sitemap-output-path
.zig-cache/conformance/c03/trailing/_boris/proof/artifacts.json
.zig-cache/conformance/c03/trailing/_boris/search/search-index.json
.zig-cache/conformance/c03/trailing/café.html
.zig-cache/conformance/c03/trailing/draft.html
.zig-cache/conformance/c03/trailing/guides.assets/notes.txt
.zig-cache/conformance/c03/trailing/guides.html
.zig-cache/conformance/c03/trailing/guides/install.html
.zig-cache/conformance/c03/trailing/index.html
.zig-cache/conformance/c03/trailing/meta/discovery.xml
```

The malformed-site-URL command exited `2`:

```text
./zig-out/bin/boris --html --input docs/audits/publication-conformance/c03-sitemap/content --html-dir .zig-cache/conformance/c03/invalid-relative --html-layout docs/audits/publication-conformance/c03-sitemap/layout.html --sitemap --site-url 'relative'
```

Its first diagnostic line was `error: invalid value for --input`, followed by
the full CLI usage text. `mailto:` and other malformed URL shapes behaved the
same way with exit `2`. The contract requires the usage exit class and rejects
non-HTTP(S) site URLs; it does not promise exact bad-flag attribution. The
misattribution is therefore a low-severity **Documented limitation** of the
best-effort CLI diagnostic, not a sitemap conformance defect. A separate CLI
diagnostics card could teach `findBadArg` about sitemap and RSS value flags.

### C03 classification

No `Confirmed defect` or `Likely defect` was found in the tested sitemap
surface. Trailing-slash normalization, percent-encoded Unicode paths, XML
escaping, draft exclusion, nested output paths, and deterministic ordering all
matched the contract and golden.

The 50,000-URL and 50 MiB limits are covered by focused sitemap-module tests;
this small CLI tree does not attempt to materialize either huge integration
fixture.

## C04 — RSS 2.0

### Exact commands and results

The three success commands all exited `0`, with quiet stdout/stderr and
byte-for-byte feed comparisons:

```text
./zig-out/bin/boris --rss --input docs/audits/publication-conformance/c04-rss/content --rss-path .zig-cache/conformance/c04/feed-2.xml --site-url 'https://example.test/docs&guides/' --rss-title 'Docs & <Feed> "News"' --rss-description 'Recent & <updates> "quotes"' --rss-limit 2 --quiet
./zig-out/bin/boris --rss --input docs/audits/publication-conformance/c04-rss/content --rss-path .zig-cache/conformance/c04/feed-3.xml --site-url 'https://example.test/docs&guides/' --rss-title 'Docs & <Feed> "News"' --rss-description 'Recent & <updates> "quotes"' --rss-limit 3 --quiet
./zig-out/bin/boris --rss --input docs/audits/publication-conformance/c04-rss/content --rss-path .zig-cache/conformance/c04/feed-4.xml --site-url 'https://example.test/docs&guides/' --rss-title 'Docs & <Feed> "News"' --rss-description 'Recent & <updates> "quotes"' --rss-limit 4 --quiet
```

The feed item counts were exactly 2, 3, and 4. The complete eligible order was
`posts/a`, `posts/b`, `posts/c`, `posts/d`: publication timestamp descending,
then canonical id ascending for the `2026-02-01` tie. The draft and
summary-only pages were excluded. The sensitive title, summary, site URL,
feed metadata, Unicode title, tag token, and ampersand/angle-bracket content
were XML escaped in the output. The deterministic feed hashes were:

```text
feed-2.xml  877457a21d508f248c1846e8a2ddda4a8d6ee07695717b8ef2bb57fd2a2fa7de
feed-3.xml  4b5b5310c6b64030d1f536d8ad9389af34495fb492d2f0eaf76a770560c96763
feed-4.xml  0ee59fa0b81ec56d6d003a44b7eaefd057927fade5b8792d815e9e832be0dfde
```

The RSS target listing was:

```text
.zig-cache/conformance/c04/feed-2.xml
.zig-cache/conformance/c04/feed-3-repeat.xml
.zig-cache/conformance/c04/feed-3.xml
.zig-cache/conformance/c04/feed-4.xml
```

The repeatability command exited `0` and matched `feed-3.xml`:

```text
./zig-out/bin/boris --rss --input docs/audits/publication-conformance/c04-rss/content --rss-path .zig-cache/conformance/c04/feed-3-repeat.xml --site-url 'https://example.test/docs&guides/' --rss-title 'Docs & <Feed> "News"' --rss-description 'Recent & <updates> "quotes"' --rss-limit 3 --quiet
```

The content-validation failure command exited `1`:

```text
./zig-out/bin/boris --rss --input docs/audits/publication-conformance/c04-rss/cases/missing-summary/content --rss-path .zig-cache/conformance/c04/missing-summary-streams.xml --site-url 'https://example.test' --rss-title Docs --rss-description Updates
```

Its stdout was zero bytes. Its exact stderr, including the four progress lines,
is retained at
`c04-rss/cases/missing-summary/expected/stderr.txt`; no feed was written.
The parser categorizes `published_at` without a non-empty `summary` as
`EFRONTMATTER`, as required.

Invalid limits `0` and `501` each exited `2`; omitting each required
`--site-url`, `--rss-title`, and `--rss-description` also exited `2`. The CLI
printed its full usage text after the parse diagnostic. These are configuration
failures, not content failures.

### C04 classification

No `Confirmed defect` or `Likely defect` was found in the tested RSS surface.
The `N-1/N/N+1` limit matrix, tie ordering, eligibility, escaping, metadata,
repeatability, and content/config exit classes all match the contract.

The CLI's best-effort bad-flag attribution for malformed RSS values is the same
`Documented limitation` described for C03; the required exit class is correct.
The retained fixtures do not prove behavior at 500 eligible items or the RSS
XML size ceiling; those are untested integration boundaries, not failures of
this four-page corpus.

## C08 — parser limits and Unicode

### Retained CLI cases

The successful Unicode graph command exited `0`, with zero stdout and this
exact stderr transcript:

```text
./zig-out/bin/boris --no-rag --input docs/audits/publication-conformance/c08-parser-unicode/content --out .zig-cache/conformance/c08/valid-unicode-rerun
boris: load  scanning docs/audits/publication-conformance/c08-parser-unicode/content
boris: roll  parsing 3 page(s)
boris: ignite validating graph
boris: ignite emitting IR → .zig-cache/conformance/c08/valid-unicode-rerun
boris: reset done (3 page(s))
ok: wrote IR under .zig-cache/conformance/c08/valid-unicode-rerun (3 page(s))
```

The generated `graph.json` matched
`c08-parser-unicode/expected/graph.json`; its SHA-256 is
`33f4a4c9f9cb306c01bafd47e8ce9e6ccffe7d19c941fd75e97a276f712b98e0`.
The graph retains `docs/東京`, `Café 東京 🧪`, `café`, `東京 🧪`, the parent
edge, and the `relates_to=target` relation.

The successful IR target listing was:

```text
.zig-cache/conformance/c08/valid-unicode-rerun/build-report.json
.zig-cache/conformance/c08/valid-unicode-rerun/graph.json
.zig-cache/conformance/c08/valid-unicode-rerun/manifest.json
```

The malformed-key and BOM commands exited `1`, with zero stdout and exact
stderr snapshots in their case directories:

```text
./zig-out/bin/boris --no-rag --input docs/audits/publication-conformance/c08-parser-unicode/cases/malformed-unicode/content --out .zig-cache/conformance/c08/malformed-streams
boris: load  scanning docs/audits/publication-conformance/c08-parser-unicode/cases/malformed-unicode/content
boris: roll  parsing 1 page(s)
boris: ignite validating graph
boris: content validation failed (1 error(s))
error: EFRONTMATTER: bad.md:2:1: unsupported frontmatter key [Fix the frontmatter or encoding for this file]

./zig-out/bin/boris --no-rag --input docs/audits/publication-conformance/c08-parser-unicode/cases/bom/content --out .zig-cache/conformance/c08/bom-streams
boris: load  scanning docs/audits/publication-conformance/c08-parser-unicode/cases/bom/content
boris: roll  parsing 1 page(s)
boris: ignite validating graph
boris: content validation failed (1 error(s))
error: EINVALIDUTF8: bom.md:1:1: UTF-8 BOM is not allowed [Fix the frontmatter or encoding for this file]
```

Neither invalid case wrote a manifest or graph.

### Automated boundary coverage

The focused `src/parser.zig` additions exercise exact and `+1` behavior for
the following established limits, with successful values also checked at
`limit - 1`:

| Contract bound | Value | Focused result |
|---|---:|---|
| Source bytes | 1 MiB | `-1` and exact accepted; `+1` `EFRONTMATTER` |
| Frontmatter bytes inside fences | 64 KiB | `-1` and exact accepted; `+1` `EFRONTMATTER` |
| Title bytes | 512 | `-1` and exact accepted; `+1` `EFRONTMATTER` |
| Summary bytes | 1,024 | `-1` and exact accepted; `+1` `EFRONTMATTER` |
| Entity id / parent bytes | 255 | both fields tested at `-1`, exact, `+1` |
| Tag token bytes | 64 | `-1` and exact accepted; `+1` `EFRONTMATTER` |
| Tag count | 32 | `31` and `32` accepted; `33` `EFRONTMATTER` |
| Relation count | 16 | `15` and `16` accepted; `17` `EFRONTMATTER` |

The same focused test preserves a decomposed combining mark without
normalization, retains CJK and emoji bytes, rejects a Unicode key as the
closed-grammar `EFRONTMATTER` category, and rejects truncated `E2 82` as
`EINVALIDUTF8`. Existing parser and `unicode_policy.zig` tests cover CRLF,
leading BOM, invalid `FF`, noncharacters, bidi controls, interior BOM, and
legitimate emoji/Indic/CJK zero-width sequences.

The contract also states a 32-field bound. Under the current closed grammar
there are only eight recognized unique keys; duplicate recognized keys fail
before 32 and an unknown key fails immediately. A valid input cannot currently
reach that numeric threshold. This is **Insufficient evidence**, not a
confirmed parser defect. The smallest follow-up is to clarify whether the
field-count bound is defense-in-depth for future keys (and add a synthetic
parser-only test if so) or remove/reframe it as an unreachable implementation
guard.

### C08 classification

No `Confirmed defect` or `Likely defect` was found in the exercised parser or
Unicode behavior. The only material gap is the unreachable field-count
boundary above. Full invalid-UTF-8 bytes and the BOM are retained, and the
CLI/IR outputs show no truncation, panic, or partial manifest publication.

## Overall disposition

The retained C02, C03, C04, and C08 evidence supports the current contracts in
the tested surface. There is no product fix in this branch. Findings requiring
follow-up are limited to:

1. **Insufficient evidence — include expansion budgets:** assign normative
   numeric ownership to the existing byte and expansion-count guards, then add
   boundary fixtures.
2. **Insufficient evidence — frontmatter field count:** reconcile the 32-field
   contract bound with the closed eight-key grammar and make the boundary
   executable or explicitly defensive.
3. **Documented limitation — CLI bad-flag attribution:** optionally extend
   `findBadArg` for sitemap/RSS value flags; this is separate from publication
   output conformance because all tested usage cases returned exit `2`.

The release-gate and aggregate test results are recorded in the agent
completion report accompanying this evidence branch. Generated site, feed,
IR, stream, and Zig-cache outputs remain ignored and uncommitted.
