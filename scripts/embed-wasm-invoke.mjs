#!/usr/bin/env node
// Test host for the M5 compileBundle wasm ABI. Not product compiler code.
// Usage: node scripts/embed-wasm-invoke.mjs <module.wasm> [markdown]
// Prints graph.json bytes to stdout.

import { readFileSync } from "node:fs";
import { argv, stdout, stderr, exit } from "node:process";

const wasmPath = argv[2];
if (!wasmPath) {
  stderr.write("usage: embed-wasm-invoke.mjs <module.wasm> [markdown]\n");
  exit(2);
}
const markdown = argv[3] ?? "---\ntitle: Home\nstatus: published\n---\n# Home\n";

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

const md = Buffer.from(markdown, "utf8");
const mdPtr = exp.boris_alloc(md.length);
if (md.length !== 0 && mdPtr === 0) {
  stderr.write("boris_alloc markdown failed\n");
  exit(1);
}
if (md.length !== 0) new Uint8Array(exp.memory.buffer, mdPtr, md.length).set(md);

const req = Buffer.from(
  JSON.stringify({
    html: false,
    files: [{ path: "index.md", ptr: mdPtr, len: md.length }],
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
const manifest = JSON.parse(Buffer.from(new Uint8Array(exp.memory.buffer, manPtr, manLen)).toString("utf8"));
const graph = manifest.artifacts.find((a) => a.path === "graph.json");
if (!graph) {
  stderr.write(`no graph.json in ${JSON.stringify(manifest)}\n`);
  exit(1);
}
const ptr = exp.boris_result_artifact_ptr(handle, graph.index);
const len = exp.boris_result_artifact_len(handle, graph.index);
stdout.write(Buffer.from(new Uint8Array(exp.memory.buffer, ptr, len)));
exp.boris_result_free(handle);
if (wasiCalls.length !== 0) {
  stderr.write(`wasi stubs were called: ${wasiCalls.join(",")}\n`);
  exit(1);
}
