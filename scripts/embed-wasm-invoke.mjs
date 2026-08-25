#!/usr/bin/env node
// Test host for the compileBundle wasm ABI. Not product compiler code.
// Usage:
//   node scripts/embed-wasm-invoke.mjs <module.wasm> [markdown]
//   node scripts/embed-wasm-invoke.mjs <module.wasm> --html --evidence \
//     --file path hostfile --print artifact-path|--manifest
// Default stdout is graph.json (M5 compat). Failed compiles still print the
// result manifest when --manifest is set; otherwise they exit 1.

import { readFileSync } from "node:fs";
import { argv, stdout, stderr, exit } from "node:process";

const wasmPath = argv[2];
if (!wasmPath) {
  stderr.write(
    "usage: embed-wasm-invoke.mjs <module.wasm> [--html] [--evidence] [--manifest] [--print PATH] [--file logical host] [markdown]\n",
  );
  exit(2);
}

let html = false;
let evidence = false;
let printManifest = false;
let printPath = null;
const files = [];
const rest = argv.slice(3);
for (let i = 0; i < rest.length; i++) {
  const arg = rest[i];
  if (arg === "--html") html = true;
  else if (arg === "--evidence") evidence = true;
  else if (arg === "--manifest") printManifest = true;
  else if (arg === "--print") {
    printPath = rest[++i];
    if (!printPath) {
      stderr.write("--print requires a path\n");
      exit(2);
    }
  } else if (arg === "--file") {
    const logical = rest[++i];
    const host = rest[++i];
    if (!logical || !host) {
      stderr.write("--file requires logical and host paths\n");
      exit(2);
    }
    files.push({ path: logical, bytes: readFileSync(host) });
  } else if (/^--[a-z]/.test(arg)) {
    stderr.write(`unexpected argument: ${arg}\n`);
    exit(2);
  } else if (files.length === 0) {
    // Positional markdown, including frontmatter that starts with `---`.
    files.push({
      path: "index.md",
      bytes: Buffer.from(arg, "utf8"),
    });
  } else {
    stderr.write(`unexpected argument: ${arg}\n`);
    exit(2);
  }
}
if (files.length === 0) {
  files.push({
    path: "index.md",
    bytes: Buffer.from("---\ntitle: Home\nstatus: published\n---\n# Home\n", "utf8"),
  });
}

const bytes = readFileSync(wasmPath);
const wasiCalls = [];
const trap = (name) => (..._args) => {
  wasiCalls.push(name);
  throw new Error(`wasi stub called: ${name}`);
};
const wasi = {};
for (const name of [
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
]) {
  wasi[name] = trap(name);
}
const { instance } = await WebAssembly.instantiate(bytes, {
  wasi_snapshot_preview1: wasi,
});
const exp = instance.exports;
for (const name of [
  "memory",
  "boris_alloc",
  "boris_compile",
  "boris_last_status",
  "boris_result_artifact_count",
  "boris_result_artifact_ptr",
  "boris_result_artifact_len",
  "boris_result_manifest_ptr",
  "boris_result_manifest_len",
  "boris_result_free",
]) {
  if (exp[name] === undefined) {
    stderr.write(`missing export ${name}\n`);
    exit(2);
  }
}

const fileRefs = [];
for (const file of files) {
  const ptr = exp.boris_alloc(file.bytes.length);
  if (file.bytes.length !== 0 && ptr === 0) {
    stderr.write(`boris_alloc failed for ${file.path}\n`);
    exit(1);
  }
  if (file.bytes.length !== 0) {
    new Uint8Array(exp.memory.buffer, ptr, file.bytes.length).set(file.bytes);
  }
  fileRefs.push({ path: file.path, ptr, len: file.bytes.length });
}

const req = Buffer.from(
  JSON.stringify({
    html,
    evidence,
    files: fileRefs,
  }),
  "utf8",
);
const reqPtr = exp.boris_alloc(req.length);
if (reqPtr === 0) {
  stderr.write("boris_alloc request failed\n");
  exit(1);
}
new Uint8Array(exp.memory.buffer, reqPtr, req.length).set(req);

const handle = exp.boris_compile(reqPtr, req.length);
if (handle === 0) {
  stderr.write(`boris_compile failed status=${exp.boris_last_status()}\n`);
  exit(1);
}
const manPtr = exp.boris_result_manifest_ptr(handle);
const manLen = exp.boris_result_manifest_len(handle);
const manifestBytes = Buffer.from(new Uint8Array(exp.memory.buffer, manPtr, manLen));
const manifest = JSON.parse(manifestBytes.toString("utf8"));

if (printManifest) {
  stdout.write(manifestBytes);
} else {
  const wanted = printPath ?? "graph.json";
  const art = manifest.artifacts.find((a) => a.path === wanted);
  if (!art) {
    stderr.write(`no ${wanted} in ${JSON.stringify(manifest)}\n`);
    exp.boris_result_free(handle);
    exit(1);
  }
  const ptr = exp.boris_result_artifact_ptr(handle, art.index);
  const len = exp.boris_result_artifact_len(handle, art.index);
  stdout.write(Buffer.from(new Uint8Array(exp.memory.buffer, ptr, len)));
}
exp.boris_result_free(handle);
if (wasiCalls.length !== 0) {
  stderr.write(`wasi stubs were called: ${wasiCalls.join(",")}\n`);
  exit(1);
}

