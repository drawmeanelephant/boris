<!--
Filename: 652-editor-validation-daemon.md
Keep exactly one category heading. Replace this example link with a relevant
repository-root-relative link; contract-visible work links its updated contract.
-->

### Added

- The editor host adopts `boris validate --watch --report` as a long-lived
  validation daemon per project (issue #652): when the installed compiler
  accepts `--watch`, the first validate demand spawns one zero-write daemon
  (`validate --input content --report .boris/html-build-report.json --watch`,
  with `--cooklang` on Cooklang trees) and `/api/commands/run` validate serves
  the newest report instead of spawning a compiler subprocess per request.
  The host watches the report file (mtime + size), maps each cycle's `ok` to
  the one-shot outcome convention (0 success / 1 content failure), reaps
  unexpected daemon deaths non-blockingly and recovers with bounded
  exponential backoff, and SIGTERMs the daemon on host exit (no orphans).
  `GET /api/validate-state` exposes `{supported, state, cycle, failure_class,
  problems_count}` and `/api/version` advertises `supported.validate_watch`;
  the shell polls the cycle counter and refreshes the problems surface only
  when the daemon rewrites the report. Compilers without `--watch` keep the
  byte-identical one-shot validate path. Pinned by the new
  `editor/scripts/test-validation-daemon.sh` host integration and the
  Playwright suite; documented in [editor/README.md](/editor/README.md).
