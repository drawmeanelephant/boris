### Fixed

- Standard.site publish now accepts a plan whose `inputs.pds_origin` is
  `null` (profile omitted `pds`) by binding to the session PDS, and planned
  document tags are owned copies so `renderPlan` cannot use freed page
  input slices. See the
  [reconciliation contract](/docs/contracts/standard-site-reconciliation.md)
  and issues
  [#580](https://github.com/drawmeanelephant/boris/issues/580) and
  [#579](https://github.com/drawmeanelephant/boris/issues/579).
