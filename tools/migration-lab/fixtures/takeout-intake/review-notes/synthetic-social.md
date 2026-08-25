# Synthetic social fixture review

Status: synthetic fixture only; no provider behavior validated.

The fixture intentionally uses generic JSON records named `posts`, `albums`,
`media`, and `links` to exercise the intake vocabulary. Those names are not a
claim that Facebook, Instagram, or Google Takeout uses these files or fields.

Privacy review:

- No real names, emails, account IDs, GPS, device data, private media, tokens,
  or unredacted URLs are present.
- `example.invalid` is reserved documentation space, not a live source.
- The SVG is newly authored synthetic media, not an extracted personal asset.

Evidence still required for a real adapter run:

- exact source bytes and source/provider revision;
- adapter command and tool versions;
- output and repeated-run hashes;
- duplicate and media collision decisions;
- explicit timezone and provenance decisions;
- privacy scrub evidence before any fixture is committed.

Next card: obtain a small, consented, sanitized export from one provider and
write a provider-specific adapter report without changing this fixture's
provider-neutral contract.
