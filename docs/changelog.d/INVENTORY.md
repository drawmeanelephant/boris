# Queued-fragment inventory

Audited against `afterparty` commit `9505ec6` (2026-08-04). This is release
bookkeeping, not released history: the release owner alone decides whether and
when to assemble these retained inputs into `CHANGELOG.md`.

`Landed` means the cited commit is reachable from that `afterparty` commit.
`Kind` describes the release-note surface, not a claim that every change is a
core-product feature. No duplicate was mechanically proven: similarly scoped
fragments describe distinct commits or acceptance surfaces and remain retained.

| Fragment | Category | PR / commit | Landed | Kind | Action |
|---|---|---|---|---|---|
| `001-product-rag-context-segments.md` | Added | `5306da5` | yes | user/contract-visible | retained numeric fragment; added bullet marker |
| `002-context-rag-export-correctness.md` | Fixed | `5306da5` | yes | contract-visible | retained numeric fragment |
| `002-doc-link-resolution.md` | Added | `5306da5` | yes | user/contract-visible | retained numeric fragment |
| `003-rag-manifest-continuation.md` | Fixed | `5306da5` | yes | contract-visible | retained numeric fragment |
| `192-completion-report-protocol.md` | Docs | PR #192 / `21e1e4d` | yes | documentation | renamed from unnumbered |
| `194-emoji-kitchen-portability-prototype.md` | Docs | PR #194 / `07fd3d3` | yes | documentation | renamed from unnumbered |
| `198-takeout-lab-intake.md` | Docs | PR #198 / `1843de7` | yes | documentation | renamed; added heading and root-relative link |
| `201-heading-harvest-allocator-fix.md` | Fixed | PR #201 / `66059a5` | yes | internal hardening | renamed from unnumbered |
| `202-meta-instagram-encoding.md` | Fixed | PR #202 / `4b57e84` | yes | developer tool | renamed from unnumbered |
| `203-instagram-lab-hostile-dump-hardening.md` | Fixed | PR #203 / `6dcbf91` | yes | developer tool | renamed from unnumbered |
| `204-ir-json-schemas.md` | Added | PR #204 / `1171190` | yes | contract-visible | renamed from unnumbered |
| `205-incremental-dirty-set-lookup.md` | Changed | PR #205 / `8901890` | yes | user-visible | renamed from unnumbered |
| `207-source-rag-pack-by-tool.md` | Added | PR #207 / `e390276` | yes | developer tool | renamed from unnumbered |
| `208-source-rag-root-fixtures.md` | Fixed | PR #208 / `2d4e844` | yes | developer tool | renamed from unnumbered |
| `209-docs-maintenance-tool.md` | Added | PR #215 / `c22c02a` | yes | developer tool | retained numeric fragment |
| `216-audit-export-safety-and-links.md` | Fixed | PR #216 / `6654ac8` | yes | user/contract-visible | renamed from unnumbered |
| `218-audit-identity-and-read-bounds.md` | Fixed | PR #218 / `fd9a2e2` | yes | user/contract-visible | renamed from unnumbered |
| `219-audit-html-diagnostic-polish.md` | Fixed | PR #219 / `6c41560` | yes | internal hardening | renamed from unnumbered |
| `221-assemble-temp-cleanup.md` | Fixed | PR #221 / `bede183` | yes | user-visible | renamed from unnumbered |
| `222-ir-export-safety.md` | Security | PR #222 / `34c1eda` | yes | user/contract-visible | renamed from unnumbered |
| `223-prevent-symlink-publish.md` | Security | PR #223 / `2ab481c` | yes | user/contract-visible | renamed from unnumbered |
| `224-cli-command-contract.md` | Changed | PR #224 / `a650738` | yes | contract-visible | renamed; normalized heading and links |
| `225-cli-process-contract.md` | Added | PR #225 / `5fc4e31` | yes | test-only | renamed; normalized heading and links |
| `226-relationship-slug-objects.md` | Changed | PR #226 / `fdaf50e` | yes | developer tool | renamed; added heading and corrected shape spelling |
| `227-source-rag-path-safety.md` | Fixed | PR #227 / `c781d61` | yes | developer tool | renamed; added heading |
| `230-docs-site-polish.md` | Changed | PR #230 / `9a41e23` | yes | user-visible | retained numeric fragment |
| `231-rendered-search-index.md` | Added | PR #231 / `a548612` | yes | user/contract-visible | retained numeric fragment |
| `233-rendered-search-cli-hardening.md` | Fixed | PR #233 / `62a91c3` | yes | developer tool | retained numeric fragment |
| `234-standalone-tools-ci.md` | Added | PR #234 / `1e0ff15` | yes | test-only | retained numeric fragment |
| `235-nested-documentation-hierarchy.md` | Changed | PR #235 / `d16dc7a` | yes | user/contract-visible | retained numeric fragment |
| `236-human-first-docs-ia.md` | Docs | PR #236 / `7995305` | yes | documentation | retained numeric fragment |
| `237-rendered-search-ui-publication.md` | Added | PR #244 / `16bcd89` | yes | user/contract-visible | retained numeric fragment |
| `238-archive-layout-audit-fixture.md` | Docs | PR #238 / `905a584` | yes | documentation/test-only | renamed from unnumbered |
| `239-relationship-target-inventory.md` | Added | PR #241 / `e6959b0` | yes | developer tool | retained numeric fragment |
| `245-v081-candidate-identifier.md` | Changed | PR #245 / `b25c7dc` | yes | contract-visible | retained numeric fragment |
| `246-relationship-candidate-classification.md` | Added | PR #246 / `7983871` | yes | developer tool | retained numeric fragment |
| `247-combined-docs-site.md` | Docs | PR #248 / `a3ae39e` | yes | documentation | retained numeric fragment |
| `247-link-audit-creates-output-dir.md` | Fixed | PR #247 / `ce750a3` | yes | developer tool | retained numeric fragment |
| `249-docs-passes-1-3-and-truth-corrections.md` | Docs | PR #249 / `d9635f2` | yes | documentation | retained numeric fragment |
| `251-search-marker-names-and-index-ownership.md` | Docs | PR #251 / `41986cc` | yes | documentation | retained numeric fragment |
| `252-search-root-attr-name-match.md` | Fixed | PR #252 / `dfbd455` | yes | user-visible | retained numeric fragment |
| `253-output-link-audit.md` | Added | PR #253 / `9a43d39` | yes | user/contract-visible | retained numeric fragment |
| `254-diagnostic-full-source-lines.md` | Fixed | PR #254 / `3457cde` | yes | user-visible | retained numeric fragment |
| `255-inline-code-directives.md` | Fixed | PR #255 / `c21c958` | yes | user/contract-visible | retained numeric fragment |
| `256-agent-binary-kits.md` | Added | PR #268 / `25f03fd` | yes | developer tool | retained numeric fragment |
| `258-search-index-control-characters.md` | Security | PR #258 / `1693dc0` | yes | security | retained numeric fragment |
| `259-structured-output-encoding.md` | Fixed | PR #259 / `fe8243f` | yes | security | retained numeric fragment |
| `260-emitter-regression-gate.md` | Security | PR #260 / `75a6554` | yes | security/test-only | retained numeric fragment |
| `261-image-data-url-media-types.md` | Security | PR #261 / `645ece6` | yes | security | retained numeric fragment |
| `262-active-svg-assets.md` | Security | PR #262 / `e61f0ae` | yes | security | retained numeric fragment |
| `263-unicode-ingest-policy.md` | Security | PR #263 / `c24def7` | yes | security | retained numeric fragment |
| `264-rss-2-export.md` | Added | PR #265 / `d44ebee` | yes | user/contract-visible | retained numeric fragment |
| `267-rss-url-and-emitter-gate.md` | Fixed | PR #267 / `b4e9b55` | yes | contract-visible | retained numeric fragment |
| `268-instagram-human-archive.md` | Changed | PR #269 / `8104d10` | yes | developer tool | retained numeric fragment |
| `270-wordpress-compile-test-cleanup.md` | Fixed | PR #270 / `2ea98e9` | yes | test-only | retained numeric fragment |
| `271-xml-sitemap.md` | Added | PR #271 / `8aa6883` | yes | user-visible | retained numeric fragment |
| `272-migration-publication-safety.md` | Security | PR #272 / `9380cd0` | yes | security | retained numeric fragment |
| `273-filed-frontmatter-safety.md` | Fixed | PR #280 / `a1421a7` | yes | developer tool | retained numeric fragment |
| `275-publication-profile-slice-1.md` | Added | PR #275 / `104c07e` | yes | contract-visible | retained numeric fragment |
| `277-doctor-slice-1.md` | Added | PR #277 / `7e424c0` | yes | internal hardening | retained numeric fragment |
| `278-astro-import-plan-slice.md` | Added | PR #278 / `d72e754` | yes | developer tool | retained numeric fragment |
| `279-astro-import-apply-slice-b1.md` | Added | PR #279 / `129e7cc` | yes | developer tool | retained numeric fragment |
| `281-filed-native-scan.md` | Added | PR #281 / `53e5d4b` | yes | developer tool | retained numeric fragment |
| `281-filed-report-semantics.md` | Changed | PR #281 / `70797a0` | yes | developer tool | retained numeric fragment |
| `281-filed-scan-canonical-relations.md` | Fixed | PR #281 / `c764e44` | yes | developer tool | retained numeric fragment |
| `282-agent-pack-all-tools.md` | Changed | PR #285 / `7529fa1` | yes | developer tool | retained numeric fragment |
| `282-arbitrary-depth-hierarchy.md` | Changed | PR #283 / `e82c5ff` | yes | contract-visible | retained numeric fragment |
| `282-boris-testdata-generator.md` | Added | PR #284 / `5bdad2a` | yes | test-only | retained numeric fragment |
| `282-publication-model-contract.md` | Docs | PR #283 / `de6f5ad` | yes | documentation | retained numeric fragment |
| `284-publication-plan-declaration.md` | Added | PR #283 / `3da3765` | yes | contract-visible | retained numeric fragment |
| `285-publication-artifact-inventory.md` | Added | PR #283 / `a2fa836` | yes | contract-visible | retained numeric fragment |
| `286-testdata-profile-repairs.md` | Fixed | PR #286 / `1e94c68` | yes | test-only | retained numeric fragment |
| `287-publication-conformance-fixtures.md` | Docs | PR #287 / `20a5b6a` | yes | test-only | retained numeric fragment |
| `288-publication-checks-evidence.md` | Added | PR #288 / `1aed3e9` | yes | contract-visible | retained numeric fragment |
| `289-testdata-jobs-passthrough.md` | Changed | PR #289 / `ee6c82c` | yes | test-only | retained numeric fragment |
| `290-publication-claims-evidence.md` | Added | PR #290 / `c9e3dc2` | yes | contract-visible | retained numeric fragment |
| `291-publication-conformance-round-2.md` | Added | PR #291 / `3ec0cfe` | yes | test-only | retained numeric fragment |
| `292-publication-touches-contract.md` | Added | PR #292 / `34715f3` | yes | contract-visible | retained numeric fragment |
| `293-conformance-w1-s1-remediation.md` | Fixed | PR #293 / `36835a6` | yes | internal hardening | retained numeric fragment |
| `294-publication-touches-first-slice.md` | Added | PR #294 / `28aa7b1` | yes | user/contract-visible | retained numeric fragment |
| `295-touches-oom-ownership.md` | Fixed | PR #295 / `6550226` | yes | internal hardening | retained numeric fragment |
| `296-test-throughput-audit.md` | Docs | PR #296 / `bb2d821` | yes | documentation | retained numeric fragment |
| `297-publication-proof-pack-contract.md` | Added | PR #297 / `fd44a40` | yes | contract-visible | retained numeric fragment |
| `298-llms-utf8-truncation.md` | Fixed | PR #298 / `a6e3b32` | yes | user-visible | retained numeric fragment |
| `299-publication-proof-pack-v1.md` | Added | PR #299 / `8604068` | yes | user/contract-visible | retained numeric fragment |
| `303-proof-pack-semantic-rejection-tests.md` | Added | PR #303 / `bc5f2d6` | yes | test-only | retained numeric fragment |
| `304-proof-pack-html-presentation.md` | Changed | PR #304 / `1270bee` | yes | user-visible | retained numeric fragment |
| `305-proof-pack-print-disclosure-robustness.md` | Fixed | PR #305 / `8b9548d` | yes | user-visible | retained numeric fragment |
| `twentytwenty-theme-materialization-dogfood.md` | Docs | PR #242 / `8d584f2` | yes | documentation | unnumbered fragment |

The four `001`–`003` legacy numeric names intentionally remain retained as
they were found. Their filenames are numeric and therefore included by the
existing deterministic release-order command; changing them is outside this
normalization pass. The unnumbered `twentytwenty-theme-materialization-dogfood.md`
fragment is retained as found under PR #242 and is not covered by the numeric
release-order command; the release owner should decide its placement at cut.
