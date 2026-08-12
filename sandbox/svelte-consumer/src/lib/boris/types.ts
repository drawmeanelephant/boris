// Hand-written TypeScript mirror of the normative Boris IR v0.2 contract
// (docs/contracts/ir-schema.md in the Boris repo).
//
// FRICTION NOTE: Boris does not ship type declarations, so every consumer
// hand-maintains a mirror of the schema. See the spike README's friction log,
// item "hand-typed IR contract". Keep this file in sync with the contract
// only; it must never become a second authority for semantics.

export type Role = 'trunk' | 'satellite';
export type Status = 'draft' | 'published' | 'archived' | null;

/** Root shape of manifest.json. */
export interface Manifest {
	schemaVersion: '0.2.0';
	compiler: string;
	contentRoot: string;
	pageCount: number;
	pages: PageSummary[];
}

/** Page summary object in manifest.json (also the base of graph nodes). */
export interface PageSummary {
	index: number;
	id: string;
	sourcePath: string;
	role: Role;
	parent: string | null;
	title: string | null;
	status: Status;
}

/** Root shape of graph.json. */
export interface Graph {
	schemaVersion: '0.2.0';
	frozen: boolean;
	nodes: GraphNode[];
	edges: Edge[];
	reverseIndex: ReverseEntry[];
	nav: NavEntry[];
}

/** Node object in graph.json (page summary + graph-only fields). */
export interface GraphNode extends PageSummary {
	parentIndex: number | null;
	tags: string[];
	bodyOffset: number;
}

/** Typed dependency endpoint: a page entity or a raw included source file. */
export interface Endpoint {
	type: 'page' | 'source';
	value: string;
}

export type EdgeKind = 'parent' | 'include' | 'reference';

/** Direct dependency edge; sorted canonically by Boris. */
export interface Edge {
	from: Endpoint;
	to: Endpoint;
	kind: EdgeKind;
}

/** Target-keyed reverse index entry; indices into graph.edges. */
export interface ReverseEntry {
	target: Endpoint;
	incomingEdges: number[];
}

/** Per-page navigation derived by Boris from the frozen graph. */
export interface NavEntry {
	index: number;
	id: string;
	breadcrumb: number[];
	children: number[];
	siblings: number[];
}
