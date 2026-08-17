//! Cloudflare Worker entry. Imports the precompiled compileBundle module.
//! Copy zig-out/bin/boris-embed-small.wasm next to this file before deploy.

import wasmModule from "./boris-embed-small.wasm";
import { instantiate } from "./abi.mjs";
import { handleRequest } from "./handler.mjs";

// Instantiate once at module scope. This runs during isolate startup (1 s
// budget on Free and Paid), not per request (10 ms CPU budget on Free). The
// compile ABI is stateless across calls, so one instance is reused for every
// request this isolate serves.
const boris = await instantiate(wasmModule);

export default {
  async fetch(request, env) {
    return handleRequest(request, env, {
      instantiateFrom: () => Promise.resolve(boris),
    });
  },
};
