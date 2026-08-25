- The `boris-standard-site-plan` artifact is now self-contained for review:
  each document entry carries the full `textContent` (the deterministic
  plain-text projection) alongside its `text_content_sha256` digest, so an
  operator can read what will be indexed without a second artifact. The digest
  and all other fields are unchanged; metadata-only documents still emit
  `null`.
