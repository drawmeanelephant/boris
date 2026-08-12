import { loadGraph, loadManifest } from '$lib/boris/data';
import { buildForest, indexNav, indexNodes } from '$lib/boris/graph';
import type { LayoutServerLoad } from './$types';

// Fully static site: every route is prerendered at build time from the
// generated Boris artifacts. There is no server at runtime.
export const prerender = true;

// Runs once per build (prerender) and on the dev server: loads the generated
// Boris IR and hands it to every page. Purely read-only consumption.
export const load: LayoutServerLoad = async () => {
	const [manifest, graph] = await Promise.all([loadManifest(), loadGraph()]);
	return {
		manifest,
		graph,
		forest: buildForest(graph),
		nodes: indexNodes(graph),
		nav: indexNav(graph)
	};
};
