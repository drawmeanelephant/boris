//! Host-side bounds for the Cloudflare Worker example (#301 M7).
//! These sit strictly below current Worker caps. They are not compiler limits.

export const LIMITS = Object.freeze({
  maxFiles: 128,
  maxFileBytes: 256 * 1024,
  maxSourceBytes: 2 * 1024 * 1024,
  maxOutputFiles: 256,
  maxOutputBytes: 8 * 1024 * 1024,
  cpuMsHint: 25_000,
  isolateMemoryMib: 96,
  workerGzipBudgetMib: 3,
});

export const WORKER_CAPS = Object.freeze({
  isolateMemoryMib: 128,
  workerGzipFreeMib: 3,
  workerGzipPaidMib: 10,
  cpuMsPaidDefault: 30_000,
  cpuMsPaidMax: 300_000,
  startupMs: 1_000,
  wasmThreads: false,
});
