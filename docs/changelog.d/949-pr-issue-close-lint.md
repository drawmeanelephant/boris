### Added

- CI now fails a PR that references an open issue without declaring, per issue, whether the merge closes it (`Closes #N` — one issue per keyword, any GitHub close synonym, no comma lists, no bold-wrapped keywords) or leaves it open (`Refs #N` / `Related to #N` — reported to the reviewer, never force-closed) — a bare `#N` mention declares neither — so multi-issue fixes can no longer orphan issues at merge time ([the PR template](/.github/PULL_REQUEST_TEMPLATE.md)).
