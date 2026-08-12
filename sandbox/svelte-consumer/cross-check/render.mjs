#!/usr/bin/env node
// Round-4 cross-check: a framework-neutral consumer of the SAME Boris feed
// the Svelte sandbox consumes (data/manifest.json + data/graph.json +
// data/bodies/{id}.html). Zero dependencies — vanilla Node, no Svelte, no
// package imports, no build step. Proves the consumer boundary is not
// Svelte-specific: any tiny renderer (Zig, Go, Rust, vanilla JS) can build a
// site from what Boris already emits.
//
// KEY FINDING the script demonstrates: its routes ARE the Boris output paths
// ({id}.html), so the output-relative .html hrefs in body fragments resolve
// with ZERO rewrite — the round-1 link-rewrite glue was a SvelteKit-routing
// concern (extensionless routes), not a Boris problem.
//
// Usage:  node cross-check/render.mjs [dataDir] [outDir]
// Defaults resolve relative to this file: ../data -> ./out
import { readFileSync, writeFileSync, mkdirSync, rmSync } from 'node:fs';
import { join, dirname, posix } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const [dataDir = join(HERE, '..', 'data'), outDir = join(HERE, 'out')] = process.argv.slice(2);

const manifest = JSON.parse(readFileSync(join(dataDir, 'manifest.json'), 'utf8'));
const graph = JSON.parse(readFileSync(join(dataDir, 'graph.json'), 'utf8'));
const nodes = new Map(graph.nodes.map((n) => [n.id, n]));
const nav = new Map(graph.nav.map((n) => [n.id, n]));
const esc = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

// Relative href between two entity output files, matching Boris's own
// output-relative link convention (identity-and-paths.md): the browser
// resolves body hrefs from the published page's directory.
const rel = (fromId, toId) => {
	const r = posix.relative(posix.dirname(`${fromId}.html`), `${toId}.html`);
	return r;
};

// Same lookups the Svelte app performs (src/lib/boris/graph.ts) — but here
// they index Boris's frozen artifacts directly, proving graph.json alone is
// sufficient for a consumer to render relations.
const refsOut = (id) =>
	graph.edges
		.filter((e) => e.kind === 'reference' && e.from.type === 'page' && e.from.value === id && e.to.type === 'page')
		.map((e) => e.to.value);
const refsIn = (id) =>
	(graph.reverseIndex.find((r) => r.target.type === 'page' && r.target.value === id)?.incomingEdges ?? [])
		.map((i) => graph.edges[i])
		.filter((e) => e.kind === 'reference' && e.from.type === 'page')
		.map((e) => e.from.value);

const page = (node) => {
	const body = readFileSync(join(dataDir, 'bodies', `${node.id}.html`), 'utf8');
	const entry = nav.get(node.id) ?? { children: [], breadcrumb: [] };
	const links = (ids) =>
		ids.map((id) => `<li><a href="${rel(node.id, id)}">${esc(nodes.get(id).title ?? id)}</a></li>`).join('');
	const sections = [];
	if (node.parent) sections.push(`<h3>Satellite of</h3><ul>${links([node.parent])}</ul>`);
	if (entry.children.length) sections.push(`<h3>Children</h3><ul>${links(entry.children.map((i) => graph.nodes[i].id))}</ul>`);
	if (refsOut(node.id).length) sections.push(`<h3>References</h3><ul>${links(refsOut(node.id))}</ul>`);
	if (refsIn(node.id).length) sections.push(`<h3>Referenced from</h3><ul>${links(refsIn(node.id))}</ul>`);
	return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>${esc(node.title ?? node.id)}</title>
<style>body{font-family:system-ui,sans-serif;max-width:60rem;margin:2rem auto;padding:0 1rem;line-height:1.5}
.chip{display:inline-block;border:1px solid #999;border-radius:999px;padding:.1rem .5rem;font-size:.75rem;margin-right:.3rem}
.prov{font-size:.8rem;color:#555}aside{border:1px dashed #999;border-radius:8px;padding:.5rem 1rem;margin-top:1.5rem}</style></head>
<body>
<h1>${esc(node.title ?? node.id)}</h1>
<div>${['trunk', 'satellite'].includes(node.role) ? `<span class="chip">${node.role}</span>` : ''}${node.status ? `<span class="chip">${node.status}</span>` : ''}${(node.tags ?? []).map((t) => `<span class="chip">${esc(t)}</span>`).join('')}</div>
<p class="prov">entity id <code>${esc(node.id)}</code> · source <code>${esc(node.sourcePath)}</code> · index ${node.index}</p>
<hr>
${body}
${sections.length ? `<aside><h2>In the Boris graph</h2>${sections.join('')}</aside>` : ''}
<p><a href="${rel(node.id, 'index')}">← all entities</a></p>
</body></html>`;
};

const indexPage = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Boris corpus — vanilla render</title></head>
<body><h1>Boris corpus — vanilla render (${manifest.pageCount} entities)</h1>
<ul>${manifest.pages.map((p) => `<li><a href="${p.id}.html">${esc(p.title ?? p.id)}</a> <small>(${p.role})</small></li>`).join('')}</ul>
<p>Rendered by <code>cross-check/render.mjs</code> from the same manifest/graph/body feed the Svelte sandbox consumes.</p>
</body></html>`;

rmSync(outDir, { recursive: true, force: true });
mkdirSync(outDir, { recursive: true });
for (const p of manifest.pages) {
	const file = join(outDir, `${p.id}.html`);
	mkdirSync(dirname(file), { recursive: true });
	writeFileSync(file, page(p));
}
writeFileSync(join(outDir, 'index.html'), indexPage);

// Self-verification against the feed's own invariants — fail loudly, not silently.
let missingBodies = 0;
for (const p of manifest.pages) {
	try {
		readFileSync(join(dataDir, 'bodies', `${p.id}.html`));
	} catch {
		missingBodies++;
	}
}
if (manifest.pageCount !== manifest.pages.length) throw new Error('manifest pageCount != pages.length');
if (manifest.pages.length !== graph.nodes.length) throw new Error('manifest pages != graph nodes');
if (missingBodies) throw new Error(`${missingBodies} entities missing body fragments`);
const overview = readFileSync(join(outDir, 'guides/overview.html'), 'utf8');
if (!overview.includes('Content Model &amp; Pipeline') || !overview.includes('trunk-satellite.html'))
	throw new Error('overview page failed spot-check (body or relation link missing)');
console.log(`ok: rendered ${manifest.pageCount} pages from feed (${graph.edges.length} edges indexed), 0 rewrite glue`);
