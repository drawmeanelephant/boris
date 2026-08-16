---
title: "Boris Source Reference Index"
id: docs/boris/src/index
status: draft
tags: [boris, zig, source-reference, index]
---

# Boris Source Reference Index

> Analytical snapshot, not a living API reference. Normative behavior is
> the implementation plus [`docs/contracts/`](../../contracts/). Read the
> [tree README](../README.md) before trusting a sentence below.

**Snapshot date:** 2026-08-16. **44** of **103** `src/*.zig` modules have
a four-page dossier. The other **59** are undocumented here on purpose.
Do not add a dossier to “complete the set.”

Every documented module is four pages:

overview
: Why the file exists. Often a paragraph behind the current CLI.

surface-and-execution
: Function-level walkthrough. High intensity. Low reward. Stale first.

evidence-and-cases
: Tests and fixtures the writer could see at the time.

review-state
: Open questions from that pass. Not a defect list.

## Documented modules (44)

* [[docs/boris/src/render|`src/render.zig`]]
* [[docs/boris/src/aside|`src/aside.zig`]]
* [[docs/boris/src/assemble|`src/assemble.zig`]]
* [[docs/boris/src/cache|`src/cache.zig`]]
* [[docs/boris/src/cli|`src/cli.zig`]]
* [[docs/boris/src/compile|`src/compile.zig`]]
* [[docs/boris/src/content_asset|`src/content_asset.zig`]]
* [[docs/boris/src/context|`src/context.zig`]]
* [[docs/boris/src/dependency|`src/dependency.zig`]]
* [[docs/boris/src/diag|`src/diag.zig`]]
* [[docs/boris/src/diagnostic|`src/diagnostic.zig`]]
* [[docs/boris/src/doclink|`src/doclink.zig`]]
* [[docs/boris/src/export_scope|`src/export_scope.zig`]]
* [[docs/boris/src/fixtures_test|`src/fixtures_test.zig`]]
* [[docs/boris/src/fuzz|`src/fuzz.zig`]]
* [[docs/boris/src/graph|`src/graph.zig`]]
* [[docs/boris/src/hardening_test|`src/hardening_test.zig`]]
* [[docs/boris/src/html_body|`src/html_body.zig`]]
* [[docs/boris/src/html_nav|`src/html_nav.zig`]]
* [[docs/boris/src/html_toc|`src/html_toc.zig`]]
* [[docs/boris/src/identity|`src/identity.zig`]]
* [[docs/boris/src/include|`src/include.zig`]]
* [[docs/boris/src/incremental_scale_smoke_test|`src/incremental_scale_smoke_test.zig`]]
* [[docs/boris/src/intelligence|`src/intelligence.zig`]]
* [[docs/boris/src/ir_emit|`src/ir_emit.zig`]]
* [[docs/boris/src/ir_schema_conformance_test|`src/ir_schema_conformance_test.zig`]]
* [[docs/boris/src/json_out|`src/json_out.zig`]]
* [[docs/boris/src/layout_select|`src/layout_select.zig`]]
* [[docs/boris/src/layout_select_hostile_test|`src/layout_select_hostile_test.zig`]]
* [[docs/boris/src/llms|`src/llms.zig`]]
* [[docs/boris/src/main|`src/main.zig`]]
* [[docs/boris/src/package|`src/package.zig`]]
* [[docs/boris/src/page|`src/page.zig`]]
* [[docs/boris/src/parser|`src/parser.zig`]]
* [[docs/boris/src/pathutil|`src/pathutil.zig`]]
* [[docs/boris/src/pipeline|`src/pipeline.zig`]]
* [[docs/boris/src/rag|`src/rag.zig`]]
* [[docs/boris/src/rag_emit|`src/rag_emit.zig`]]
* [[docs/boris/src/scanner|`src/scanner.zig`]]
* [[docs/boris/src/target|`src/target.zig`]]
* [[docs/boris/src/textile|`src/textile.zig`]]
* [[docs/boris/src/theme|`src/theme.zig`]]
* [[docs/boris/src/watch|`src/watch.zig`]]
* [[docs/boris/src/wikilink|`src/wikilink.zig`]]

## Undocumented `src/*.zig` (59)

These files exist in the compiler and have **no** dossier in this tree.
Authority is the `.zig` file and, where one exists, its contract.

| Cluster | Modules |
|---|---|
| Standard.site / AT Protocol | `atproto_authorization`, `atproto_browser_std`, `atproto_dns`, `atproto_dns_std`, `atproto_handle`, `atproto_identity`, `atproto_interactive_std`, `atproto_loopback_std`, `atproto_oauth`, `atproto_password`, `atproto_session_std`, `atproto_session_store`, `atproto_transport`, `atproto_transport_std`, `atproto_xrpc`, `standard_site`, `standard_site_emit`, `standard_site_publish`, `standard_site_reconcile`, `standard_site_smoke` |
| Publication evidence / targets | `artifact_invariants`, `artifact_inventory`, `github_pages`, `publication_checks`, `publication_claims`, `publication_location`, `publication_plan`, `publication_profile`, `publication_proof_pack`, `publication_touches` |
| Other afterparty surfaces | `cooklang_seam`, `doctor`, `encode`, `html_relations`, `html_report`, `html_scan`, `image_dimensions`, `init`, `link_audit`, `nostr`, `nostr_plan`, `preview_server`, `route_resolver`, `rss`, `rss_date`, `search_index`, `site_url`, `sitemap`, `source_io`, `structured_out`, `svg_policy`, `timings`, `unicode_policy` |
| Test-only roots without a dossier | `emitter_discipline_test`, `emitter_hostile_test`, plus the `publication_*_fixture_test` files |

## Rules of use

1. **Contracts win.** If a dossier and a contract disagree, the contract
   wins and the dossier is drift.
2. **Source wins next.** If a dossier and `src/*.zig` disagree, the source
   wins.
3. **Do not silently refresh a surface page.** A function-level rewrite
   of `surface-and-execution.md` is a project, not a drive-by. Prefer
   deleting a lie or pointing at the contract.
4. **Do not fill the 59-file gap** with more four-page packs unless a
   named issue asks for one module and names the contract it must track.
