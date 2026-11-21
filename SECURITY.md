# Security Policy

## Reporting a vulnerability

Please do not open public issues for security problems.

Report privately through GitHub: open this repository's **Security** tab
and choose **Report a vulnerability**. That opens a private channel with
the maintainers — it stays private until we agree on disclosure with you.

Include what you ran, what you expected, and what happened, plus a minimal
reproduction if you have one. This is a small project, so responses are
best effort — but we will acknowledge your report and coordinate a fix and
disclosure with you.

## Supported versions

Fixes land on `main` and ship in the next release. We don't maintain
backport branches for security fixes.

## Scope and trust model

Boris is a local compiler plus a local editor and preview server. The
generated HTML assumes **trusted author input** by design: raw HTML in
your own Markdown passes through. Putting a `<script>` in content you own
is not a vulnerability.

In scope:

- Escaping failures where a contract promises escaping (page titles,
  link text, generated attributes, IR fields).
- Path or symlink escapes — compilation or editor writes landing outside
  the project/output tree.
- Crashes, hangs, or resource exhaustion on crafted Markdown,
  frontmatter, or component input.
- Secrets leaking into logs, `dist/` output, or diagnostics — including
  the Nostr signing key and Standard.site OAuth/app-password material.
- The loopback servers (`boris watch --serve`, the editor host) being
  reachable from browser pages on other origins, e.g. via DNS rebinding
  or missing Origin/Host checks.
- Process-spawning paths (job runner, editor validation daemon, the
  OAuth browser launch) being driven into running unintended commands.

Out of scope: bugs with no security impact (file a normal issue — they're
welcome too), and vulnerabilities in hosting environments that serve the
generated static output.
