### Added

- CI now fails a PR whose body references open issues without per-issue closing keywords — one `Closes #N` line per issue, no comma lists, no bold-wrapped keywords, no `Refs #N` for issues the merge must close — so multi-issue fixes can no longer orphan issues at merge time ([the PR template](/.github/PULL_REQUEST_TEMPLATE.md)).
