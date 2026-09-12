// editor/ui/src/lib/graph-map.ts
// Deterministic layered layout for the Graph pane's visual map.
//
// Pure input, pure output: the frozen `graph.json` payload in, coordinates
// and edges out. No randomness, no physics, no DOM. Depth comes from the
// frozen `nav.breadcrumb` (root = 0), leaves are slotted in depth-first
// `nav.children` order, and internal pages center over their children, so the
// same graph always produces the same picture.
//
// The one non-structural signal is `weight` — direct children plus incoming
// page references — exposed for stroke styling. It is topology, never
// content length, so an edit that does not change the graph cannot restyle
// the map. Source endpoints (`include` targets that are not pages) are
// deliberately absent: they are not nodes in `graph.json`, and the Graph
// pane's outgoing list already names them.

import type { GraphDocument } from './types';

export const MAP_NODE_HEIGHT = 30;
export const MAP_DEPTH_GAP = 84;
export const MAP_LEAF_GAP = 208;
export const MAP_MARGIN_X = 28;
export const MAP_MARGIN_Y = 24;

const LABEL_LIMIT = 24;
const MIN_NODE_WIDTH = 76;
const MAX_NODE_WIDTH = 184;
const CHAR_WIDTH = 6.6;
const NODE_PADDING = 18;

export type GraphMapNode = {
  index: number;
  id: string;
  label: string;
  role: string;
  depth: number;
  x: number;
  y: number;
  width: number;
  height: number;
  /** Direct children plus incoming page references. Topology only. */
  weight: number;
};

export type GraphMapEdge = {
  kind: 'parent' | 'reference';
  from: { x: number; y: number };
  to: { x: number; y: number };
};

export type GraphMapLayout = {
  nodes: GraphMapNode[];
  edges: GraphMapEdge[];
  width: number;
  height: number;
};

/** Title-else-id, whitespace-flattened, truncated for a single SVG line. */
export function graphMapLabel(id: string, title: string | null): string {
  const raw = (title ?? '').trim();
  const text = (raw.length > 0 ? raw : id).replace(/\s+/g, ' ');
  return text.length > LABEL_LIMIT ? `${text.slice(0, LABEL_LIMIT - 1)}…` : text;
}

function nodeWidth(label: string): number {
  const measured = NODE_PADDING + label.length * CHAR_WIDTH;
  return Math.min(MAX_NODE_WIDTH, Math.max(MIN_NODE_WIDTH, measured));
}

export function layoutGraphMap(graph: GraphDocument): GraphMapLayout {
  const byId = new Map(graph.nodes.map((node) => [node.id, node]));
  const parentByIndex = new Map(graph.nodes.map((node) => [node.index, node.parentIndex]));
  const navById = new Map(graph.nav.map((entry) => [entry.id, entry]));

  const depth = new Map<number, number>();
  for (const node of graph.nodes) {
    const entry = navById.get(node.id);
    depth.set(node.index, entry ? Math.max(0, entry.breadcrumb.length - 1) : 0);
  }

  // Children in frozen nav order; a nav-less payload falls back to parent
  // pointers so the map still lays out.
  const childrenByIndex = new Map<number, number[]>();
  for (const node of graph.nodes) {
    const entry = navById.get(node.id);
    if (entry) {
      childrenByIndex.set(node.index, [...entry.children]);
    } else {
      childrenByIndex.set(
        node.index,
        graph.nodes.filter((candidate) => parentByIndex.get(candidate.index) === node.index).map((candidate) => candidate.index)
      );
    }
  }

  const roots = graph.nodes.filter((node) => {
    const parent = node.parent;
    return parent === null || !byId.has(parent);
  });
  const rootOrder = roots.length > 0 ? roots : graph.nodes;

  // Depth-first leaf slots in node order: each subtree stays contiguous.
  const slot = new Map<number, number>();
  let nextSlot = 0;
  const visited = new Set<number>();
  for (const root of rootOrder) {
    const stack = [root.index];
    while (stack.length > 0) {
      const index = stack.pop() as number;
      if (visited.has(index)) continue;
      visited.add(index);
      const children = childrenByIndex.get(index) ?? [];
      if (children.length === 0) {
        slot.set(index, nextSlot);
        nextSlot += 1;
        continue;
      }
      for (let i = children.length - 1; i >= 0; i--) stack.push(children[i]);
    }
  }

  const leafX = (position: number): number => MAP_MARGIN_X + position * MAP_LEAF_GAP + MAP_LEAF_GAP / 2;
  const xByIndex = new Map<number, number>();
  for (const [index, position] of slot) xByIndex.set(index, leafX(position));

  const byDepthDescending = [...graph.nodes].sort(
    (left, right) => (depth.get(right.index) ?? 0) - (depth.get(left.index) ?? 0) || left.index - right.index
  );
  for (const node of byDepthDescending) {
    if (xByIndex.has(node.index)) continue;
    const children = (childrenByIndex.get(node.index) ?? []).filter((child) => xByIndex.has(child));
    if (children.length === 0) {
      xByIndex.set(node.index, leafX(nextSlot));
      nextSlot += 1;
      continue;
    }
    const first = xByIndex.get(children[0]) as number;
    const last = xByIndex.get(children[children.length - 1]) as number;
    xByIndex.set(node.index, (first + last) / 2);
  }

  const incomingRefs = new Map<string, number>();
  for (const edge of graph.edges) {
    if (edge.kind !== 'reference' || edge.to.type !== 'page') continue;
    incomingRefs.set(edge.to.value, (incomingRefs.get(edge.to.value) ?? 0) + 1);
  }

  const maxDepth = graph.nodes.reduce((deepest, node) => Math.max(deepest, depth.get(node.index) ?? 0), 0);
  const nodes: GraphMapNode[] = graph.nodes.map((node) => {
    const label = graphMapLabel(node.id, node.title);
    const nodeDepth = depth.get(node.index) ?? 0;
    return {
      index: node.index,
      id: node.id,
      label,
      role: node.role,
      depth: nodeDepth,
      x: xByIndex.get(node.index) ?? leafX(0),
      y: MAP_MARGIN_Y + nodeDepth * MAP_DEPTH_GAP + MAP_NODE_HEIGHT / 2,
      width: nodeWidth(label),
      height: MAP_NODE_HEIGHT,
      weight: (childrenByIndex.get(node.index) ?? []).length + (incomingRefs.get(node.id) ?? 0)
    };
  });

  const centerByIndex = new Map(nodes.map((node) => [node.index, node]));
  const edges: GraphMapEdge[] = [];
  for (const node of nodes) {
    const parentIndex = parentByIndex.get(node.index) ?? null;
    if (parentIndex === null) continue;
    const parent = centerByIndex.get(parentIndex);
    if (!parent) continue;
    edges.push({ kind: 'parent', from: { x: parent.x, y: parent.y }, to: { x: node.x, y: node.y } });
  }
  for (const edge of graph.edges) {
    if (edge.kind !== 'reference' || edge.from.type !== 'page' || edge.to.type !== 'page') continue;
    const from = byId.get(edge.from.value);
    const to = byId.get(edge.to.value);
    if (!from || !to || from.id === to.id) continue;
    const fromNode = centerByIndex.get(from.index);
    const toNode = centerByIndex.get(to.index);
    if (!fromNode || !toNode) continue;
    edges.push({ kind: 'reference', from: { x: fromNode.x, y: fromNode.y }, to: { x: toNode.x, y: toNode.y } });
  }

  return {
    nodes,
    edges,
    width: MAP_MARGIN_X * 2 + Math.max(1, nextSlot) * MAP_LEAF_GAP,
    height: MAP_MARGIN_Y * 2 + maxDepth * MAP_DEPTH_GAP + MAP_NODE_HEIGHT
  };
}
