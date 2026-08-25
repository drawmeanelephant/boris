<!-- Filename: 780-usage-and-search-fixes.md -->

### Fixed

- Missing-content-root failures on the HTML path now name the probed content
  root and the create-or-`--input` remediation (#779), matching the IR
  pipeline wording; the `EIO` exit class is unchanged.
  [diagnostics contract](/docs/contracts/diagnostics.md).
- Usage errors (exit 2) print their self-attributing cause plus one synopsis
  line instead of the full help text; full options remain opt-in via
  `--help`, and the standard-site family keeps its subcommand list (#777).
  [cli contract](/docs/contracts/cli.md).
- Rendered-site search now joins successive code fragments with single spaces
  and keeps word boundaries around inline-code spans, so indexed terms such as
  `otool -L` match as whole tokens instead of one concatenated blob (#778);
  the text/code field split is unchanged. Evidence-chain goldens were
  re-pinned for the new index bytes.
  [rendered-search contract](/docs/contracts/rendered-search.md).
