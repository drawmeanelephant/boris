### Fixed

- Fixed Cooklang name termination at the Boris seam: a `{` later in the line no
  longer swallows prose into the ingredient name, so
  `Add @salt into the {bowl} and stir.` yields ingredient `salt` with no
  quantity and keeps `{bowl}` in the prose — enforcing the adjacency rule in
  the [Cooklang compatibility contract](/docs/contracts/cooklang-compatibility.md)
  via the repinned Oliver parser ([Oliver renderer pin](/docs/contracts/oliver-renderer.md),
  #907).
