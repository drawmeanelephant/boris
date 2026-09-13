// editor/ui/src/lib/state/graph.svelte.ts
// The Boris graph surface: /api/graph payload plus every read-only
// derivation the graph pane and palette need — the node for the open buffer,
// its parent, children, siblings, outgoing references and includes,
// backlinks, completion relations, and the wiki links present in the buffer.

import { api } from '../api';
import {
  graphLinksForIndices,
  incomingGraphLinks,
  navForNode,
  nodeForId,
  nodeForPath,
  outgoingGraphLinks,
  wikiLinksInSource
} from '../utils';
import type { GraphLink, GraphNode, GraphPayload, GraphExportFormat } from '../types';
import { buffer } from './buffer.svelte';
import { authoring } from './authoring.svelte';

export const graph = $state({
  payload: null as GraphPayload | null,
  status: 'Loading the Boris graph…',
  exportFormat: 'mermaid' as GraphExportFormat,
  document: null as string | null,
  copied: false
});

export function activeNode(): GraphNode | null {
  return nodeForPath(graph.payload?.graph ?? null, buffer.activePath);
}

export function parentNode(): GraphNode | null {
  const node = activeNode();
  if (!node?.parent) return null;
  return nodeForId(graph.payload?.graph ?? null, node.parent);
}

export function graphChildren(): GraphLink[] {
  return graphLinksForIndices(graph.payload?.graph ?? null, navForNode(graph.payload?.graph ?? null, activeNode())?.children ?? []);
}

export function graphSiblings(): GraphLink[] {
  return graphLinksForIndices(graph.payload?.graph ?? null, navForNode(graph.payload?.graph ?? null, activeNode())?.siblings ?? []);
}

export function graphOutgoing(): GraphLink[] {
  return outgoingGraphLinks(graph.payload?.graph ?? null, activeNode());
}

export function graphBacklinks(): GraphLink[] {
  return incomingGraphLinks(graph.payload?.graph ?? null, activeNode());
}

export function graphRelations(): Array<{ kind: string; target: string }> {
  return (authoring.payload?.completion?.entities ?? []).find(entity => entity.id === activeNode()?.id)?.relations ?? [];
}

export function bufferWikiLinks(): Array<{ id: string; node: GraphNode | null }> {
  return wikiLinksInSource(buffer.content).map(id => ({ id, node: nodeForId(graph.payload?.graph ?? null, id) }));
}

export function setGraph(payload: GraphPayload) {
  graph.payload = payload;
  if (payload.graph_status === 'unsupported') {
    graph.status = 'graph.json is stale or unsupported. Build diagnostics to replace it.';
    return;
  }
  graph.status = payload.graph
    ? `Boris graph ready (${payload.graph.nodes.length} pages).`
    : 'Build diagnostics to create the Boris graph.';
}

export async function refreshGraph() {
  graph.status = 'Refreshing the Boris graph…';
  const result = await api<GraphPayload>('/api/graph');
  if (result.response.ok) setGraph(result.data);
  else graph.status = 'The Boris build succeeded, but graph.json could not be adapted.';
}

let copiedExportTimer: ReturnType<typeof setTimeout> | undefined;

export function setGraphExportFormat(format: GraphExportFormat) {
  if (graph.exportFormat === format) return;
  graph.exportFormat = format;
  graph.document = null;
  graph.copied = false;
}

export async function copyGraphDocument() {
  if (!graph.document) return;
  try {
    await navigator.clipboard.writeText(graph.document);
    graph.copied = true;
    if (copiedExportTimer !== undefined) clearTimeout(copiedExportTimer);
    copiedExportTimer = setTimeout(() => {
      graph.copied = false;
      copiedExportTimer = undefined;
    }, 1500);
  } catch {
    graph.status = 'Could not copy the graph export. Clipboard access was denied.';
  }
}

export function downloadGraphDocument() {
  if (!graph.document) return;
  const ext = graph.exportFormat === 'dot' ? 'dot' : 'mmd';
  const blob = new Blob([graph.document], { type: 'text/plain;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const link = document.createElement('a');
  link.href = url;
  link.download = `graph.${ext}`;
  link.click();
  URL.revokeObjectURL(url);
}
