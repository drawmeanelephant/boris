- `boris standard-site records --profile PATH [--out PATH]` dumps the full
  canonical Standard.site record payloads (publication + eligible documents,
  including each document's complete `textContent`) as
  `boris-standard-site-records` (schema v1). It shares the compile +
  projection pipeline with `plan`/`publish` and is fully offline: no discovery,
  OAuth, transport, or mutation. Byte-identical output for identical inputs.
