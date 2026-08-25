//! HTTP compile handler. No Markdown parsing. Host glue only.

import { LIMITS, WORKER_CAPS } from "./limits.mjs";
import { canonicalizeFiles } from "./paths.mjs";
import { compile } from "./abi.mjs";
import { compilePrefix, uploadArtifacts } from "./r2.mjs";

export function decodeRequestFiles(body) {
  if (!body || !Array.isArray(body.files)) {
    const err = new Error("request.files must be an array");
    err.code = "BAD_REQUEST";
    throw err;
  }
  return body.files.map((file, i) => {
    if (!file || typeof file.path !== "string") {
      const err = new Error(`files[${i}].path is required`);
      err.code = "BAD_REQUEST";
      throw err;
    }
    let bytes;
    if (typeof file.bytes === "string") {
      bytes = Uint8Array.from(atob(file.bytes), (c) => c.charCodeAt(0));
    } else if (file.bytes instanceof Uint8Array) {
      bytes = file.bytes;
    } else {
      const err = new Error(`files[${i}].bytes must be base64 or Uint8Array`);
      err.code = "BAD_REQUEST";
      throw err;
    }
    return { path: file.path, bytes };
  });
}

export function enforceSourceLimits(files) {
  if (files.length > LIMITS.maxFiles) {
    const err = new Error(`too many files: ${files.length} > ${LIMITS.maxFiles}`);
    err.code = "LIMIT_FILES";
    throw err;
  }
  let total = 0;
  for (const file of files) {
    if (file.bytes.length > LIMITS.maxFileBytes) {
      const err = new Error(
        `file too large: ${file.path} ${file.bytes.length} > ${LIMITS.maxFileBytes}`,
      );
      err.code = "LIMIT_FILE_BYTES";
      throw err;
    }
    total += file.bytes.length;
  }
  if (total > LIMITS.maxSourceBytes) {
    const err = new Error(`source bundle too large: ${total} > ${LIMITS.maxSourceBytes}`);
    err.code = "LIMIT_SOURCE_BYTES";
    throw err;
  }
}

export function enforceOutputLimits(artifacts) {
  if (artifacts.length > LIMITS.maxOutputFiles) {
    const err = new Error(
      `too many artifacts: ${artifacts.length} > ${LIMITS.maxOutputFiles}`,
    );
    err.code = "LIMIT_OUTPUT_FILES";
    throw err;
  }
  let total = 0;
  for (const art of artifacts) total += art.bytes.length;
  if (total > LIMITS.maxOutputBytes) {
    const err = new Error(`artifact package too large: ${total} > ${LIMITS.maxOutputBytes}`);
    err.code = "LIMIT_OUTPUT_BYTES";
    throw err;
  }
}

function sha256HexSync(bytes) {
  return crypto.subtle.digest("SHA-256", bytes).then((buf) => {
    const hex = [...new Uint8Array(buf)]
      .map((b) => b.toString(16).padStart(2, "0"))
      .join("");
    return hex;
  });
}

function evidenceSummary(artifacts, ok) {
  const has = (path) => artifacts.some((a) => a.path === path);
  const claims = artifacts.find((a) => a.path === "_boris/proof/claims.json");
  let claim_statuses = null;
  if (claims) {
    try {
      const parsed = JSON.parse(new TextDecoder().decode(claims.bytes));
      claim_statuses = (parsed.claims ?? []).map((c) => ({
        id: c.id,
        status: c.status,
      }));
    } catch {
      claim_statuses = [];
    }
  }
  const verified = (claim_statuses ?? []).filter((c) => c.status === "verified");
  return {
    artifacts: has("_boris/proof/artifacts.json"),
    checks: has("_boris/proof/checks.json"),
    claims: has("_boris/proof/claims.json"),
    touches: has("_boris/proof/touches.json"),
    proof_pack: has("_boris/proof/proof-pack.json"),
    claim_statuses,
    successful_claims: ok ? verified.length : 0,
  };
}

export async function runCompile(abi, body, env = {}) {
  const started = Date.now();
  const files = canonicalizeFiles(decodeRequestFiles(body));
  enforceSourceLimits(files);

  const result = compile(abi, {
    html: body.html === true,
    evidence: body.evidence === true,
    layout_path: typeof body.layout_path === "string" ? body.layout_path : "layouts/main.html",
    files,
  });
  enforceOutputLimits(result.artifacts);

  const elapsed_ms = Date.now() - started;
  const evidence = evidenceSummary(result.artifacts, result.ok);
  if (!result.ok && evidence.successful_claims > 0) {
    const err = new Error("failed compile emitted verified publication claims");
    err.code = "FALSE_CLAIM";
    throw err;
  }

  // sha256 is opt-in (`include_sha256`): per-artifact hashing costs host CPU
  // and response bytes for large bundles (measured ~0–7 ms at 89 artifacts on
  // 2026-08-16), so leave it off unless the caller needs integrity digests.
  const includeSha = body.include_sha256 === true;
  const manifest = [];
  for (const art of result.artifacts) {
    const entry = {
      path: art.path,
      media_type: art.media_type,
      bytes: art.bytes.length,
    };
    if (includeSha) entry.sha256 = await sha256HexSync(art.bytes);
    manifest.push(entry);
  }

  let r2 = null;
  if (result.ok && env.ARTIFACTS) {
    const prefix = body.r2_prefix ?? compilePrefix();
    r2 = await uploadArtifacts(env.ARTIFACTS, prefix, result.artifacts);
    for (let i = 0; i < manifest.length; i++) {
      manifest[i].r2_key = r2.keys[i];
    }
  }

  return {
    ok: result.ok,
    status: result.status,
    version: result.version,
    profile: result.manifest.profile ?? null,
    features: result.manifest.features ?? [],
    unsupported: result.manifest.unsupported ?? [],
    compiler_id: result.manifest.compiler_id ?? null,
    diagnostics: result.manifest.diagnostics ?? [],
    artifacts: manifest,
    evidence,
    r2,
    elapsed_ms,
    limits: LIMITS,
    worker_caps: WORKER_CAPS,
  };
}

function jsonResponse(body, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8" },
  });
}

export async function handleRequest(request, env, { instantiateFrom }) {
  if (request.method === "GET" && new URL(request.url).pathname === "/health") {
    return jsonResponse({
      ok: true,
      service: "boris-embed-worker",
      limits: LIMITS,
      worker_caps: WORKER_CAPS,
    });
  }
  if (request.method !== "POST") {
    return jsonResponse({ ok: false, error: { code: "METHOD", message: "POST /compile" } }, 405);
  }

  let body;
  try {
    body = await request.json();
  } catch {
    return jsonResponse({ ok: false, error: { code: "BAD_JSON", message: "invalid JSON" } }, 400);
  }

  try {
    const abi = await instantiateFrom();
    const result = await runCompile(abi, body, env);
    const http = result.ok ? 200 : result.status === 1 ? 422 : 500;
    return jsonResponse(result, http);
  } catch (err) {
    const code = err.code ?? "HOST_ERROR";
    const status =
      code === "BAD_REQUEST" ||
      code === "INVALID_PATH" ||
      code === "DUPLICATE_PATH" ||
      String(code).startsWith("LIMIT_")
        ? 400
        : 500;
    return jsonResponse(
      { ok: false, error: { code, message: err.message }, limits: LIMITS },
      status,
    );
  }
}
