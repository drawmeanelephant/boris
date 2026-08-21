### Security

- Fix stored XSS in `boris-content-audit` HTML report: escape collection names, policy type names, record ids, and CLI values (`--revision`, source root) via `util.appendHtmlEscaped` and harden Markdown report against `|`/backtick table breakout and fenced-block injection ([`tools/content-audit/src/report_html.zig`](/tools/content-audit/src/report_html.zig), [`tools/content-audit/src/report_md.zig`](/tools/content-audit/src/report_md.zig), [`tools/content-audit/src/util.zig`](/tools/content-audit/src/util.zig), [#709](https://github.com/drawmeanelephant/boris/issues/709)).
