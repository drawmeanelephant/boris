import { error } from '@sveltejs/kit';
import { loadBodyFragment, rewriteInternalLinks } from '$lib/boris/body';
import {
	breadcrumbOf,
	includedSources,
	incomingReferences,
	outgoingReferences
} from '$lib/boris/graph';
import type { GraphNode } from '$lib/boris/types';
import type { PageServerLoad } from './$types';

// Detail route: /[...id] — the entity id (which may contain '/') is the URL.
// This works because Boris entity ids are canonical, path-safe, and unique
// (identity-and-paths.md), so no slug map is needed: id === route path.
export const load: PageServerLoad = async ({ params, parent }) => {
	const id = params.id;
	const { graph, nodes, nav } = await parent();

	const node = nodes.get(id);
	if (!node) throw error(404, `No Boris entity with id "${id}"`);

	const navEntry = nav.get(id);
	const children = (navEntry?.children ?? []).map((i) => nodes.get(graph.nodes[i].id)!);
	const siblings = (navEntry?.siblings ?? []).map((i) => nodes.get(graph.nodes[i].id)!);
	const parentNode: GraphNode | null = node.parentIndex != null ? nodes.get(graph.nodes[node.parentIndex].id)! : null;

	// Body fragment is Boris-rendered; only internal hrefs are re-targeted.
	const body = await loadBodyFragment(id).catch(() => null);

	return {
		id,
		node,
		body: body ? rewriteInternalLinks(body, id) : null,
		breadcrumb: navEntry ? breadcrumbOf(graph, navEntry, nodes) : [node],
		parent: parentNode,
		children,
		siblings,
		incoming: incomingReferences(graph, id, nodes),
		outgoing: outgoingReferences(graph, id, nodes),
		includes: includedSources(graph, id)
	};
};
