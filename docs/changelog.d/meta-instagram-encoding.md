### Fixed

- Instagram migration-lab JSON captions now repair Meta's escaped
  Latin-1/UTF-8 form when the result validates as UTF-8, with provenance and
  regression coverage for multipart exports. See
  [`tools/migration-lab/README.md`](../tools/migration-lab/README.md).
