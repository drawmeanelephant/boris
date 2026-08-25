### Fixed

- The rendered-search publication check now treats an emitted `status: draft`
  page as an ineligible subject instead of reporting a missing search document
  for intended state. The artifact inventory records per-page advertisement
  (`"advertised": true/false/null`, optional-on-parse), and the check's
  eligible subject set mirrors the search producer's own filtered slice while
  staleness detection stays active.
  Links: [publication-checks contract](/docs/contracts/publication-checks.md),
  [publication-artifacts contract](/docs/contracts/publication-artifacts.md),
  [#752](https://github.com/drawmeanelephant/boris/issues/752).
