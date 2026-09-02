#!/usr/bin/env node
// Render a human-readable job-summary markdown block from an editor gate log.
//
// The gate (test-editor-gate.sh) ends every outcome — success or failure —
// with exactly one machine-readable NDJSON line on stdout. This helper reads
// that log, finds the trailing {"event":"editor-gate",…} line (scanning from
// the end so intermediate "OK"/"FAIL" noise is skipped), and renders it as a
// GitHub job-summary markdown block: an ok/boris/total header, a stage table
// (stage, ok, ms), and the raw JSON in a code fence. When no summary line is
// present (an exotic pre-summary failure) it says so and quotes the log tail,
// so a dashboard consumer never silently gets stale data.
//
// Usage:
//   node editor/scripts/editor-gate-summary.mjs LOG [MARKDOWN_OUT]
//
// With MARKDOWN_OUT the block is written to that file ($GITHUB_STEP_SUMMARY
// in CI); otherwise it is printed to stdout.
import { readFileSync, writeFileSync } from 'node:fs';

const [logPath, markdownOut] = process.argv.slice(2);
if (!logPath) {
  console.error('usage: node editor/scripts/editor-gate-summary.mjs LOG [MARKDOWN_OUT]');
  process.exit(2);
}

let log = '';
try {
  log = readFileSync(logPath, 'utf8');
} catch {
  // fall through: an unreadable log yields the "no summary" block below
}

const lines = log.split('\n');
let raw = '';
for (let i = lines.length - 1; i >= 0; i--) {
  const line = lines[i].trim();
  if (line.startsWith('{"event":"editor-gate"')) {
    raw = line;
    break;
  }
}

let summary = null;
if (raw) {
  try {
    summary = JSON.parse(raw);
  } catch {
    summary = null;
  }
}

const md = ['## Editor gate summary'];
if (summary) {
  md.push('');
  if (summary.boris) md.push(`- **boris:** \`${summary.boris}\``);
  md.push(`- **ok:** ${summary.ok}`);
  if (typeof summary.total_ms === 'number') {
    md.push(`- **total:** ${summary.total_ms} ms`);
  }
  if (summary.reason) {
    md.push(`- **reason:** ${summary.reason}`);
  }
  if (Array.isArray(summary.stages) && summary.stages.length > 0) {
    md.push('');
    md.push('| stage | ok | ms |');
    md.push('|---|---|---|');
    for (const stage of summary.stages) {
      const name = String(stage.stage).replaceAll('|', '\\|').replaceAll('\n', ' ');
      md.push(`| ${name} | ${stage.ok ? '✅' : '❌'} | ${stage.ms} |`);
    }
  }
  md.push('');
  md.push('```json');
  md.push(JSON.stringify(summary));
  md.push('```');
} else {
  md.push('');
  md.push('_No `editor-gate` summary line was found — the gate likely failed before '
    + 'emitting one. Full log tail:_');
  if (lines.length > 0) {
    md.push('');
    md.push('```text');
    md.push(...lines.slice(-6));
    md.push('```');
  }
}

const out = `${md.join('\n')}\n`;
if (markdownOut) {
  writeFileSync(markdownOut, out, 'utf8');
} else {
  process.stdout.write(out);
}
