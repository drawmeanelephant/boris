#!/usr/bin/env node
// Test host for the M0 render wasm module. Not product compiler code.
// Usage: node scripts/render-wasm-invoke.mjs <module.wasm> [markdown]

import { readFileSync } from "node:fs";
import { argv, stdout, stderr, exit } from "node:process";

const wasmPath = argv[2];
if (!wasmPath) {
  stderr.write("usage: render-wasm-invoke.mjs <module.wasm> [markdown]\n");
  exit(2);
}
const markdown = argv[3] ?? "# Alpha\n";

const bytes = readFileSync(wasmPath);
const { instance } = await WebAssembly.instantiate(bytes, {});
const exp = instance.exports;
for (const name of ["memory", "boris_alloc", "boris_render", "boris_result_ptr", "boris_result_len"]) {
  if (exp[name] === undefined) {
    stderr.write(`missing export ${name}\n`);
    exit(2);
  }
}

const input = Buffer.from(markdown, "utf8");
const inPtr = exp.boris_alloc(input.length);
if (input.length !== 0 && inPtr === 0) {
  stderr.write("boris_alloc failed\n");
  exit(1);
}
if (input.length !== 0) {
  new Uint8Array(exp.memory.buffer, inPtr, input.length).set(input);
}

const status = exp.boris_render(inPtr, input.length);
if (status !== 0) {
  stderr.write(`boris_render status ${status}\n`);
  exit(1);
}
const ptr = exp.boris_result_ptr();
const len = exp.boris_result_len();
stdout.write(Buffer.from(new Uint8Array(exp.memory.buffer, ptr, len)));
