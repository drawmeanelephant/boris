### Security

- Prevent HTML publication from following symlinks below output root by validating destination parent directory components with no-follow semantics during staging commit. Links: [HTML output contract](/docs/contracts/html-output.md#symlink-safety-below-output-root-h-03).
