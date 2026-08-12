// Loads Boris-rendered body fragments from data/bodies/{id}.html.
//
// TEMPORARY GLUE — spike deliverable. Boris's HTML contract emits
// output-relative hrefs ending in .html (e.g. `guides/overview.html` or
// `../index.html`). SvelteKit routes are extensionless and root-relative. This
// function rewrites internal page links so the frozen, Boris-rendered body
// works inside a SvelteKit route.
//
// The rewrite does NOT resolve wiki-links or re-derive anything: Boris already
// resolved `[[id]]` -> relative .html hrefs at compile time. This only
// re-targets those hrefs to the consuming framework's routing scheme. See the
// friction log entry "body links are output-relative .html hrefs".
import { readFile } from 'node:fs/promises';
import { join, posix } from 'node:path';
import { DATA_DIR } from './data';

export async function loadBodyFragment(id: string): Promise<string> {
	return readFile(join(DATA_DIR, 'bodies', `${id}.html`), 'utf8');
}

const SKIP_SCHEMES = /^(mailto|tel|data|javascript):/i;

export function rewriteInternalLinks(body: string, id: string): string {
	// Body hrefs are relative to the published HTML file's directory, which is
	// the same as the entity id's directory (identity-and-paths.md).
	const dir = posix.dirname(id); // '' for top-level ids
	const base = `https://boris.invalid/${dir}${dir ? '/' : ''}`;

	return body.replace(/href="([^"]*)"/g, (match, href: string) => {
		const trimmed = href.trim();
		if (
			trimmed === '' ||
			trimmed.startsWith('#') ||
			trimmed.includes('://') ||
			SKIP_SCHEMES.test(trimmed)
		) {
			return match;
		}
		// Only page links end in .html in Boris output. Assets and unknown
		// targets are left untouched (this corpus has no page-local assets).
		if (!trimmed.endsWith('.html')) return match;

		const url = new URL(trimmed, base);
		// url.pathname already begins with '/' (root-relative); do not add
		// another slash or links become '//agents'.
		const route = `${url.pathname.replace(/\.html$/, '')}${url.search}${url.hash}`;
		return `href="${route}"`;
	});
}
