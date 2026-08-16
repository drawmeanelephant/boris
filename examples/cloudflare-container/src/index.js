/**
 * Official Cloudflare host for boris-job-runner.
 *
 * The Worker authenticates and forwards a source archive. The container
 * execs native boris. This file is host glue, not a compiler.
 *
 * Optional R2 binding name: JOBS. Without it the Worker still returns
 * the result JSON. Secrets stay in the Worker; enableInternet is false.
 */
import { Container } from "@cloudflare/containers";

export class BorisJobRunner extends Container {
  defaultPort = 8080;
  sleepAfter = "15s";
  enableInternet = false;
}

const jsonHeaders = { "content-type": "application/json; charset=utf-8" };

function unauthorized() {
  return new Response(JSON.stringify({ ok: false, runnerClass: "auth" }) + "\n", {
    status: 401,
    headers: jsonHeaders,
  });
}

function bearerOk(request, token) {
  if (!token) return false;
  const header = request.headers.get("authorization") || "";
  if (!header.startsWith("Bearer ")) return false;
  return header.slice("Bearer ".length) === token;
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/health") {
      const container = env.BORIS_JOBS.getByName("runner");
      return container.fetch(new Request("http://container/health", { method: "GET" }));
    }

    if (request.method !== "POST" || (url.pathname !== "/v1/jobs" && url.pathname !== "/v1/jobs/package")) {
      return new Response("not found\n", { status: 404 });
    }

    if (!bearerOk(request, env.BORIS_JOB_TOKEN)) return unauthorized();

    const archive = await request.arrayBuffer();
    const command = url.searchParams.get("command") || "build";
    const jobId = url.searchParams.get("jobId") || "";
    const wantPackage = url.pathname === "/v1/jobs/package" || env.JOBS;

    const containerPath = wantPackage ? "/v1/jobs/package" : "/v1/jobs";
    const qs = new URLSearchParams();
    if (command) qs.set("command", command);
    if (jobId) qs.set("jobId", jobId);
    const query = qs.toString();

    const container = env.BORIS_JOBS.getByName(jobId || "runner");
    const upstream = await container.fetch(
      new Request(`http://container${containerPath}${query ? `?${query}` : ""}`, {
        method: "POST",
        headers: {
          "content-type": "application/x-tar",
          authorization: `Bearer ${env.BORIS_JOB_TOKEN}`,
        },
        body: archive,
      }),
    );

    const bytes = await upstream.arrayBuffer();
    const contentType = upstream.headers.get("content-type") || "";

    if (env.JOBS && contentType.includes("application/x-tar")) {
      const keyJob = jobId || "latest";
      const key = `jobs/${keyJob}/package.tar`;
      await env.JOBS.put(key, bytes, {
        httpMetadata: { contentType: "application/x-tar" },
      });
    }

    return new Response(bytes, {
      status: upstream.status,
      headers: {
        "content-type": contentType || "application/json; charset=utf-8",
      },
    });
  },
};
