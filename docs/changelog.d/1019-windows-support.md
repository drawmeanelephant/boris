## Fixed

- Windows builds and runs natively: `zig build` installs a `boris` POSIX
  launcher shim beside `boris.exe`, threaded-I/O file opens and readers
  follow Windows async semantics, the preview server shuts down without
  an overlapped-accept panic, and test scripts account for Windows
  signal, jq-CRLF, and symlink behaviors. `zig build test` is green on
  Windows Server 2022 (208 steps, 16518 tests). See
  [the PR](https://github.com/drawmeanelephant/boris/pull/1019).
