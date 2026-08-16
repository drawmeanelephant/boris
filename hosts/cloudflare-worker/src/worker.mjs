//! Cloudflare Worker entry. Imports the precompiled compileBundle module.
//! Copy zig-out/bin/boris-embed-small.wasm next to this file before deploy.

import wasmModule from "./boris-embed-small.wasm";
import { instantiate } from "./abi.mjs";
import { handleRequest } from "./handler.mjs";

export default {
  async fetch(request, env) {
    return handleRequest(request, env, {
      instantiateFrom: () => instantiate(wasmModule),
    });
  },
};
