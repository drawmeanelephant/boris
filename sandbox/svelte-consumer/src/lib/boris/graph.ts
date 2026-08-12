// Pure lookups over the frozen Boris graph. These helpers only *index* what
// Boris already validated and froze (ir-schema.md v0.2). They deliberately do
// not re-derive roles, parents, or edges — that would reproduce Boris
// semantics inside Svelte, which this spike must not do.
import type { Edge, Graph, GraphNode, NavEntry } from './types';

export interface ForestItem {
	node: GraphNode;
	children: GraphNode[];
}

/** id -> node index map, built once per load. */
export function indexNodes(graph: Graph): Map<string, GraphNode> {
	const m = new Map<string, GraphNode>();
	for (const n of graph.nodes) m.set(n.id, n);
	return m;
}

/** id -> nav entry map (nav is already id-ordered, same as nodes). */
export function indexNav(graph: Graph): Map<string, NavEntry> {
	const m = new Map<string, NavEntry>();
	for (const nav of graph.nav) m.set(nav.id, nav);
	return m;
}

/** Trunk forest: trunks in Boris's id-ascending order, each with children. */
export function buildForest(graph: Graph): ForestItem[] {
	const nodes = indexNodes(graph);
	const nav = indexNav(graph);
	const forest: ForestItem[] = [];
	for (const node of graph.nodes) {
		if (node.role !== 'trunk') continue;
		const entry = nav.get(node.id);
		forest.push({
			node,
			children: (entry?.children ?? []).map((i) => nodes.get(graph.nodes[i].id)!)
		});
	}
	return forest;
}

export function breadcrumbOf(graph: Graph, nav: NavEntry, nodes: Map<string, GraphNode>): GraphNode[] {
	return nav.breadcrumb.map((i) => nodes.get(graph.nodes[i].id)!);
}

export interface RelatedPage {
	node: GraphNode;
	kind: 'reference' | 'parent';
}

/** Pages that reference this page (via reverseIndex -> edges, kind reference). */
export function incomingReferences(graph: Graph, id: string, nodes: Map<string, GraphNode>): RelatedPage[] {
	const out: RelatedPage[] = [];
	const entry = graph.reverseIndex.find((r) => r.target.type === 'page' && r.target.value === id);
	if (!entry) return out;
	for (const edgeIndex of entry.incomingEdges) {
		const edge = graph.edges[edgeIndex];
		if (edge.kind === 'reference' && edge.from.type === 'page') {
			const node = nodes.get(edge.from.value);
			if (node) out.push({ node, kind: edge.kind });
		}
	}
	return out;
}

/** Pages this page references directly (kind reference). */
export function outgoingReferences(graph: Graph, id: string, nodes: Map<string, GraphNode>): RelatedPage[] {
	const out: RelatedPage[] = [];
	for (const edge of graph.edges) {
		if (edge.kind === 'reference' && edge.from.type === 'page' && edge.from.value === id && edge.to.type === 'page') {
			const node = nodes.get(edge.to.value);
			if (node) out.push({ node, kind: edge.kind });
		}
	}
	return out;
}

/** Source files included by this page (kind include, from = page). */
export function includedSources(graph: Graph, id: string): string[] {
	const out: string[] = [];
	for (const edge of graph.edges) {
		if (edge.kind === 'include' && edge.from.type === 'page' && edge.from.value === id && edge.to.type === 'source') {
			out.push(edge.to.value);
		}
	}
	return out;
}
