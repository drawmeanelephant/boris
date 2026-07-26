# Queued-fragment inventory

Audited against `afterparty` commit `c87bee3` (2026-07-26). This is release
bookkeeping, not released history: the release owner alone decides whether and
when to assemble these retained inputs into `CHANGELOG.md`.

`Landed` means the cited commit is reachable from that `afterparty` commit.
`Kind` describes the release-note surface, not a claim that every change is a
core-product feature. No duplicate was mechanically proven: similarly scoped
fragments describe distinct commits or acceptance surfaces and remain retained.

| Fragment | Category | PR / commit | Landed | Kind | Action |
|---|---|---|---|---|---|
| `001-apex-v1.1.13.md` | Changed | `1829f12` | yes | contract-visible | retained numeric fragment |
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
| `238-archive-layout-audit-fixture.md` | Docs | PR #238 / `905a584` | yes | documentation/test-only | renamed from unnumbered |

The four `001`–`003` legacy numeric names intentionally remain retained as
they were found. Their filenames are numeric and therefore included by the
existing deterministic release-order command; changing them is outside this
normalization pass.
