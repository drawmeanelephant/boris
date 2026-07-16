# Changelog fragments

Feature and fix PRs add exactly one fragment here instead of editing the shared
`CHANGELOG.md` **[Unreleased]** section. This keeps concurrent PRs from
conflicting on the release notes.

## Add a fragment

1. Copy [`TEMPLATE.md`](TEMPLATE.md) to
   `<pr-number>-<short-kebab-case-summary>.md`, for example
   `73-cache-cleanup.md`. The PR number makes the name unique.
2. Keep exactly one of the template's category headings: `Added`, `Changed`,
   `Fixed`, `Security`, or `Docs`.
3. Write one short, user-facing or contract-visible bullet. Include at least one
   repository-root-relative Markdown link such as
   `[the contract](/docs/contracts/acceptance.md)`. Contract-visible work must link
   its updated contract; add fixture, issue, or PR links when they clarify the
   acceptance surface.
4. Do not edit `CHANGELOG.md`'s **[Unreleased]** section in the feature/fix PR.

Before opening the PR, inspect the deterministic release order and whitespace:

```bash
find docs/changelog.d -maxdepth 1 -type f -name '[0-9]*-*.md' -print | LC_ALL=C sort
git diff --check -- AGENTS.md CHANGELOG.md docs/changelog.d
```

## Release-owner procedure

1. List fragments with the command above. Process categories in this order:
   `Added`, `Changed`, `Fixed`, `Security`, `Docs`; within each category, retain
   the lexical filename order from that list.
2. Copy each bullet into the matching heading in the dated release section of
   `CHANGELOG.md`, preserving its links. Create a heading only when that release
   has bullets for it.
3. Review the assembled notes, run `git diff --check`, then remove the assembled
   fragments or move them to the release archive location if the release process
   keeps one. Leave the template and this README in place.

Fragments are deliberately plain Markdown: no generator, dependency, or product
build change is required.
