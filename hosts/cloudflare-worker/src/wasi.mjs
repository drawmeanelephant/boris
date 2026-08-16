//! Trap stubs for wasi_snapshot_preview1. The memory compile path must not
//! call these. A stub firing is an ABI failure.

export const WASI_NAMES = [
  "random_get",
  "clock_time_get",
  "poll_oneoff",
  "clock_res_get",
  "environ_sizes_get",
  "environ_get",
  "fd_pwrite",
  "fd_pread",
  "fd_filestat_set_times",
  "fd_filestat_set_size",
  "fd_fdstat_get",
  "fd_sync",
  "fd_seek",
  "fd_write",
  "fd_close",
  "fd_filestat_get",
  "path_link",
  "path_readlink",
  "path_symlink",
  "path_rename",
  "path_remove_directory",
  "path_unlink_file",
  "fd_readdir",
  "path_open",
  "path_filestat_get",
  "path_create_directory",
  "fd_read",
];

export function trapWasi() {
  const calls = [];
  const imports = {};
  for (const name of WASI_NAMES) {
    imports[name] = () => {
      calls.push(name);
      throw new Error(`wasi stub called: ${name}`);
    };
  }
  return { imports, calls };
}
