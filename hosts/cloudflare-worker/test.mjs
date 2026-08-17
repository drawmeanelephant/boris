#!/usr/bin/env node
// Local smoke for the Worker host glue. Does not need Wrangler or Cloudflare
// credentials. Loads zig-out/bin/boris-embed-small.wasm.

import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { instantiate } from "./src/abi.mjs";
import { canonicalize, canonicalizeFiles } from "./src/paths.mjs";
import { LIMITS } from "./src/limits.mjs";
import { runCompile, enforceSourceLimits } from "./src/handler.mjs";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "../..");
const wasmPath = join(root, "zig-out/bin/boris-embed-small.wasm");

function fail(msg) {
  console.error(msg);
  process.exit(1);
}

function expect(cond, msg) {
  if (!cond) fail(msg);
}

function loadFile(rel) {
  const bytes = readFileSync(join(here, rel));
  return { path: rel.replace(/^fixtures\/[^/]+\//, ""), bytes };
}

function b64(bytes) {
  return Buffer.from(bytes).toString("base64");
}

class MemoryR2 {
  constructor() {
    this.store = new Map();
  }
  async put(key, value, opts) {
    this.store.set(key, { value, opts });
  }
}

try {
  canonicalize("../x.md");
  fail("expected traversal reject");
} catch (err) {
  expect(err.code === "INVALID_PATH", `traversal code: ${err.code}`);
}
try {
  canonicalize("/abs.md");
  fail("expected absolute reject");
} catch (err) {
  expect(err.code === "INVALID_PATH", `absolute code: ${err.code}`);
}
try {
  canonicalizeFiles([
    { path: "index.md", bytes: new Uint8Array() },
    { path: "./index.md", bytes: new Uint8Array() },
  ]);
  fail("expected duplicate reject");
} catch (err) {
  expect(err.code === "DUPLICATE_PATH", `duplicate code: ${err.code}`);
}

const ordered = canonicalizeFiles([
  { path: "b.md", bytes: new Uint8Array([2]) },
  { path: "a.md", bytes: new Uint8Array([1]) },
]);
expect(ordered[0].path === "a.md" && ordered[1].path === "b.md", "canonical order");

try {
  enforceSourceLimits(
    Array.from({ length: LIMITS.maxFiles + 1 }, (_, i) => ({
      path: `${i}.md`,
      bytes: new Uint8Array(1),
    })),
  );
  fail("expected file-count limit");
} catch (err) {
  expect(err.code === "LIMIT_FILES", `file limit code: ${err.code}`);
}

let wasmBytes;
try {
  wasmBytes = readFileSync(wasmPath);
} catch {
  fail(`missing ${wasmPath} — run zig build first`);
}

const abi = await instantiate(wasmBytes);
const valid = [
  loadFile("fixtures/valid/index.md"),
  loadFile("fixtures/valid/layouts/main.html"),
];
const r2 = new MemoryR2();
const ok = await runCompile(
  abi,
  {
    html: true,
    evidence: true,
    files: valid.map((f) => ({ path: f.path, bytes: b64(f.bytes) })),
    r2_prefix: "smoke/valid",
  },
  { ARTIFACTS: r2 },
);

expect(ok.ok === true, `valid compile not ok: ${JSON.stringify(ok.diagnostics)}`);
expect(ok.status === 0, `valid status ${ok.status}`);
expect(ok.artifacts.some((a) => a.path === "index.html"), "missing index.html");
expect(ok.artifacts.some((a) => a.path === "_boris/proof/artifacts.json"), "missing inventory");
expect(ok.artifacts.some((a) => a.path === "_boris/proof/claims.json"), "missing claims");
expect(ok.evidence.proof_pack === false, "proof pack should stay omitted");
expect(ok.r2 && ok.r2.keys.length === ok.artifacts.length, "R2 key count");
expect(r2.store.has("smoke/valid/index.html"), "R2 missing index.html");
expect(ok.elapsed_ms >= 0, "elapsed_ms");
console.log(
  `valid: ${ok.artifacts.length} artifacts, ${ok.elapsed_ms} ms, r2=${ok.r2.keys.length}`,
);
expect(ok.artifacts.every((a) => a.sha256 === undefined), "sha256 should be omitted by default");

const hashed = await runCompile(
  abi,
  {
    html: true,
    evidence: true,
    include_sha256: true,
    files: valid.map((f) => ({ path: f.path, bytes: b64(f.bytes) })),
    r2_prefix: "smoke/hashed",
  },
  { ARTIFACTS: new MemoryR2() },
);
expect(hashed.ok === true, "hashed compile not ok");
expect(
  hashed.artifacts.every((a) => typeof a.sha256 === "string" && a.sha256.length === 64),
  "sha256 present when include_sha256 is set",
);
console.log(`hashed: ${hashed.artifacts.length} artifacts with sha256`);

const poisoned = [
  loadFile("fixtures/poisoned/orphan.md"),
  loadFile("fixtures/poisoned/layouts/main.html"),
];
const r2fail = new MemoryR2();
const bad = await runCompile(
  abi,
  {
    html: true,
    evidence: true,
    files: poisoned.map((f) => ({ path: f.path, bytes: b64(f.bytes) })),
    r2_prefix: "smoke/poisoned",
  },
  { ARTIFACTS: r2fail },
);

expect(bad.ok === false, "poisoned compile should not be ok");
expect(bad.status === 1, `poisoned status ${bad.status}`);
expect(
  bad.diagnostics.some((d) => d.code === "EPARENTMISSING"),
  `missing EPARENTMISSING: ${JSON.stringify(bad.diagnostics)}`,
);
expect(
  !bad.artifacts.some((a) => a.path.startsWith("_boris/proof/")),
  "poisoned compile emitted evidence",
);
expect(bad.evidence.successful_claims === 0, "poisoned successful claims");
expect(bad.r2 === null, "poisoned compile uploaded to R2");
expect(r2fail.store.size === 0, "poisoned R2 store not empty");
console.log(`poisoned: status=${bad.status} diagnostics=${bad.diagnostics.length} r2=none`);

console.log("hosts/cloudflare-worker local smoke passed");
