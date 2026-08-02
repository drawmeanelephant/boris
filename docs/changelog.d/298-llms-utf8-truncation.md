<!--
Filename: 298-llms-utf8-truncation.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Fixed

- `llms.txt` summaries are now truncated at the 240-byte limit only on a valid
  UTF-8 scalar boundary, so a multibyte character is never split in the emitted
  file ([`llms.txt` contract](/docs/contracts/llms-txt.md)).
