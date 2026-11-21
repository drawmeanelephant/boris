import assert from "node:assert/strict";
import { spawn, spawnSync } from "node:child_process";
import { once } from "node:events";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { createContext, SourceTextModule, SyntheticModule } from "node:vm";

const root = process.cwd();
const out = path.resolve(process.argv[2]);
const token = "runner-auth-test-only";
const env = { ...process.env, BORIS_JOB_TOKEN: token };
const source = await readFile("examples/cloudflare-container/src/index.js", "utf8");
const context = createContext({ Request, Response, URL, URLSearchParams });
const containers = new SyntheticModule(["Container"], function () {
  this.setExport("Container", class {
    constructor(_ctx, bindings) { this.env = bindings; }
  });
}, { context });
const worker = new SourceTextModule(source, { context });
await worker.link((specifier) => {
  assert.equal(specifier, "@cloudflare/containers");
  return containers;
});
await worker.evaluate();
const host = new worker.namespace.BorisJobRunner({}, {
  BORIS_JOB_TOKEN: token,
  R2_SECRET: "must-not-enter-container",
});
assert.deepEqual({ ...host.envVars }, { BORIS_JOB_TOKEN: token });
assert.equal(host.enableInternet, false);

const archive = await readFile(path.join(out, "valid.tar"));
const forwarded = [];
const bindings = {
  BORIS_JOB_TOKEN: token,
  BORIS_JOBS: {
    getByName() {
      return {
        async fetch(request) {
          forwarded.push(request);
          return new Response('{"ok":true}\n', {
            headers: { "content-type": "application/json" },
          });
        },
      };
    },
  },
};
for (const authorization of [null, "Bearer wrong", `Bearer ${token}-more`]) {
  const headers = authorization ? { authorization } : {};
  const response = await worker.namespace.default.fetch(
    new Request("https://worker.test/v1/jobs", { method: "POST", headers, body: archive }),
    bindings,
  );
  assert.equal(response.status, 401);
}
assert.equal(forwarded.length, 0);
const response = await worker.namespace.default.fetch(
  new Request("https://worker.test/v1/jobs?jobId=auth-test", {
    method: "POST",
    headers: { authorization: `Bearer ${token}` },
    body: archive,
  }),
  bindings,
);
assert.equal(response.status, 200);
assert.equal(forwarded.length, 1);
assert.equal(forwarded[0].headers.get("authorization"), `Bearer ${host.envVars.BORIS_JOB_TOKEN}`);
assert.equal(new URL(forwarded[0].url).searchParams.get("jobId"), "auth-test");
assert.deepEqual(Buffer.from(await forwarded[0].arrayBuffer()), archive);

const dockerfile = await readFile("examples/cloudflare-container/Dockerfile", "utf8");
const command = JSON.parse(dockerfile.match(/^CMD (.+)$/m)[1]);
assert.deepEqual(command, ["--listen", "0.0.0.0:8080"]);
const runner = path.join(root, "zig-out/bin/boris-job-runner");
const listen = ["--listen", "0.0.0.0:0"];
const withoutToken = { ...env };
delete withoutToken.BORIS_JOB_TOKEN;
for (const [args, testEnv] of [
  [listen, withoutToken],
  [listen, { ...env, BORIS_JOB_TOKEN: "" }],
  [[...listen, "--allow-unauthenticated"], withoutToken],
  [["--listen", "0", "--allow-unauthenticated"], withoutToken],
]) {
  const result = spawnSync(runner, args, { env: testEnv, encoding: "utf8", timeout: 5000 });
  assert.equal(result.status, 2, result.stderr);
  assert.ok(!result.stderr.includes("listening on"));
}

async function probe(args, testEnv, authenticated) {
  const child = spawn(runner, [
    ...args, "--boris", path.join(root, "zig-out/bin/boris"), "--work-root", path.join(out, "http-ws"),
  ], { env: testEnv, stdio: ["ignore", "ignore", "pipe"] });
  try {
    const port = await new Promise((resolve, reject) => {
      let log = "";
      const timer = setTimeout(() => reject(new Error("runner startup timed out")), 5000);
      const finish = (error, value) => {
        clearTimeout(timer);
        if (error) reject(error); else resolve(value);
      };
      child.once("error", (error) => finish(error));
      child.once("exit", (code) => finish(new Error(`runner exited ${code}: ${log}`)));
      child.stderr.on("data", (bytes) => {
        log += bytes;
        const match = log.match(/listening on [\d.]+:(\d+)/);
        if (match) finish(null, Number(match[1]));
      });
    });
    const base = `http://127.0.0.1:${port}`;
    const health = await fetch(`${base}/health`, { signal: AbortSignal.timeout(5000) });
    assert.equal(health.status, 200);
    assert.equal((await health.json()).ok, true);
    if (authenticated) {
      for (const route of ["/v1/jobs", "/v1/jobs/package"]) {
        for (const authorization of [null, "Bearer wrong", `Bearer ${token}-more`]) {
          const headers = authorization ? { authorization } : {};
          const denied = await fetch(`${base}${route}`, {
            method: "POST", headers, signal: AbortSignal.timeout(5000),
          });
          assert.equal(denied.status, 401);
          assert.equal((await denied.json()).runnerClass, "auth");
        }
      }
    }
    const accepted = await fetch(`${base}/v1/jobs`, {
      method: "POST",
      headers: authenticated ? { authorization: `Bearer ${token}` } : {},
      body: archive,
      signal: AbortSignal.timeout(15000),
    });
    assert.equal(accepted.status, 200);
    const result = await accepted.json();
    assert.equal(result.ok, true);
    assert.equal(result.workspaceRemoved, true);
    assert.ok(result.artifacts.some((artifact) => artifact.path.endsWith("index.html")));
    assert.ok(!JSON.stringify(result).includes(token));
  } finally {
    if (child.exitCode === null && child.signalCode === null) {
      const exited = once(child, "exit");
      child.kill("SIGKILL");
      await exited;
    }
  }
}

await probe([command[0], command[1].replace(":8080", ":0")], env, true);
await probe(["--listen", "127.0.0.1:0", "--allow-unauthenticated"], withoutToken, false);
console.log("container host authentication: ok (Worker mocked; native runner live)");
