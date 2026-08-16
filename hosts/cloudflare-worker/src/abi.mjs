//! Thin wrapper around the compileBundle C ABI. Host glue only.

import { trapWasi } from "./wasi.mjs";

const REQUIRED = [
  "memory",
  "boris_version",
  "boris_version_len",
  "boris_alloc",
  "boris_free",
  "boris_compile",
  "boris_last_status",
  "boris_result_status",
  "boris_result_manifest_ptr",
  "boris_result_manifest_len",
  "boris_result_artifact_count",
  "boris_result_artifact_ptr",
  "boris_result_artifact_len",
  "boris_result_free",
];

function readBytes(memory, ptr, len) {
  if (len === 0) return new Uint8Array();
  return new Uint8Array(memory.buffer, ptr, len).slice();
}

function writeBytes(memory, ptr, bytes) {
  if (bytes.length === 0) return;
  new Uint8Array(memory.buffer, ptr, bytes.length).set(bytes);
}

export async function instantiate(source) {
  const wasi = trapWasi();
  const result = await WebAssembly.instantiate(source, {
    wasi_snapshot_preview1: wasi.imports,
  });
  const instance = result.instance ?? result;
  const exp = instance.exports;
  for (const name of REQUIRED) {
    if (exp[name] === undefined) {
      throw new Error(`missing wasm export ${name}`);
    }
  }
  return { exports: exp, wasiCalls: wasi.calls };
}

/**
 * @param {{exports: WebAssembly.Exports, wasiCalls: string[]}} abi
 * @param {{html?: boolean, evidence?: boolean, layout_path?: string, files: Array<{path: string, bytes: Uint8Array}>}} request
 */
export function compile(abi, request) {
  // Per-call WASI canary. wasiCalls lives on the reused instance, so reset it:
  // a stub fired by an earlier request would otherwise poison every later one.
  abi.wasiCalls.length = 0;
  const exp = abi.exports;
  const allocs = [];
  const alloc = (len) => {
    if (len === 0) return 0;
    const ptr = exp.boris_alloc(len);
    if (ptr === 0) {
      const err = new Error("boris_alloc failed");
      err.code = "WASM_OOM";
      throw err;
    }
    allocs.push({ ptr, len });
    return ptr;
  };

  try {
    const refs = [];
    for (const file of request.files) {
      const ptr = alloc(file.bytes.length);
      writeBytes(exp.memory, ptr, file.bytes);
      refs.push({ path: file.path, ptr, len: file.bytes.length });
    }
    const reqJson = new TextEncoder().encode(
      JSON.stringify({
        html: request.html === true,
        evidence: request.evidence === true,
        layout_path: request.layout_path ?? "layouts/main.html",
        files: refs,
      }),
    );
    const reqPtr = alloc(reqJson.length);
    writeBytes(exp.memory, reqPtr, reqJson);

    const handle = exp.boris_compile(reqPtr, reqJson.length);
    if (handle === 0) {
      const status = exp.boris_last_status();
      const err = new Error(`boris_compile failed status=${status}`);
      err.code = "ABI_FAILURE";
      err.status = status;
      throw err;
    }

    const status = exp.boris_result_status(handle);
    const manPtr = exp.boris_result_manifest_ptr(handle);
    const manLen = exp.boris_result_manifest_len(handle);
    const manifestBytes = readBytes(exp.memory, manPtr, manLen);
    const manifest = JSON.parse(new TextDecoder().decode(manifestBytes));

    const count = exp.boris_result_artifact_count(handle);
    const artifacts = [];
    for (let i = 0; i < count; i++) {
      const meta = manifest.artifacts[i];
      const ptr = exp.boris_result_artifact_ptr(handle, i);
      const len = exp.boris_result_artifact_len(handle, i);
      artifacts.push({
        path: meta.path,
        media_type: meta.media_type,
        bytes: readBytes(exp.memory, ptr, len),
      });
    }

    exp.boris_result_free(handle);

    if (abi.wasiCalls.length !== 0) {
      const err = new Error(`wasi stubs were called: ${abi.wasiCalls.join(",")}`);
      err.code = "WASI_USED";
      throw err;
    }

    return {
      status,
      ok: status === 0,
      manifest,
      artifacts,
      version: new TextDecoder().decode(
        readBytes(exp.memory, exp.boris_version(), exp.boris_version_len()),
      ),
    };
  } finally {
    for (const { ptr, len } of allocs) exp.boris_free(ptr, len);
  }
}
