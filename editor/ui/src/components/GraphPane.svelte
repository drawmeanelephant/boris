<script lang="ts">
  import type { GraphExportFormat, GraphNode } from '../lib/types';
  import { buffer } from '../lib/state/buffer.svelte';
  import { graph, activeNode, parentNode, graphChildren, graphSiblings, graphOutgoing, graphBacklinks, graphRelations, bufferWikiLinks, setGraphExportFormat, copyGraphDocument, downloadGraphDocument } from '../lib/state/graph.svelte';
  import { problems } from '../lib/state/problems.svelte';
  import GraphMap from './GraphMap.svelte';

  let {
    onOpenPath,
    onOpenNode,
    onImpact,
    onExport
  }: {
    onOpenPath: (path: string) => void;
    onOpenNode: (node: GraphNode | null) => void;
    onImpact: () => void;
    onExport: () => void;
  } = $props();

  // Local deriveds so the template's {#if} narrows the node to non-null.
  const node = $derived(activeNode());
  const parent = $derived(parentNode());
  const children = $derived(graphChildren());
  const siblings = $derived(graphSiblings());
  const outgoing = $derived(graphOutgoing());
  const backlinks = $derived(graphBacklinks());
  const relations = $derived(graphRelations());
  const wikiLinks = $derived(bufferWikiLinks());
  const mapDocument = $derived(graph.payload?.graph ?? null);
  const exportReady = $derived(graph.payload?.graph_status === 'ready');

  function nodeForIdLocal(id: string): GraphNode | null {
    if (!graph.payload?.graph) return null;
    return graph.payload.graph.nodes.find((n) => n.id === id) ?? null;
  }
</script>

<section id="graph" class="graph-pane" tabindex="-1" aria-labelledby="graph-heading">
  <div class="pane-heading">
    <div>
      <h3 id="graph-heading">Graph</h3>
      <p>Read-only view of Boris <code>graph.json</code> and <code>completion.json</code>.</p>
    </div>
    <div class="graph-export" aria-label="Graph export">
      <label for="graph-export-format">Export format</label>
      <select
        id="graph-export-format"
        value={graph.exportFormat}
        disabled={problems.running || !exportReady}
        onchange={(e) => setGraphExportFormat((e.currentTarget as HTMLSelectElement).value as GraphExportFormat)}
      >
        <option value="mermaid">Mermaid</option>
        <option value="dot">Graphviz DOT</option>
      </select>
      <button type="button" disabled={problems.running || !exportReady} onclick={onExport}>Export graph</button>
    </div>
  </div>
  <p role="status" aria-label="Graph status" aria-live="polite">{graph.status}</p>
  {#if graph.document}
    <div class="graph-export-document">
      <label for="graph-export-document">Exported {graph.exportFormat === 'dot' ? 'Graphviz DOT' : 'Mermaid'}</label>
      <textarea id="graph-export-document" readonly value={graph.document}></textarea>
      <div class="graph-actions">
        <button type="button" onclick={() => void copyGraphDocument()}>{graph.copied ? 'Copied!' : 'Copy export'}</button>
        <button type="button" onclick={downloadGraphDocument}>Download export</button>
      </div>
    </div>
  {/if}
  {#if mapDocument && mapDocument.nodes.length > 0}
    <GraphMap graph={mapDocument} activeId={node?.id ?? null} onOpenNode={(next) => onOpenNode(next)} />
  {/if}
  {#if node}
    <p class="graph-current">{node.id}{node.title ? ` · ${node.title}` : ''} · {node.role}{node.status ? ` · ${node.status}` : ''}</p>
    <div class="graph-actions" aria-label="Graph navigation">
      {#if parent}
        <button type="button" onclick={() => onOpenNode(parent)}>Go to parent {parent.id}</button>
      {/if}
      <button type="button" disabled={problems.running} onclick={onImpact}>Run impact on {node.id}</button>
    </div>
    {#if children.length > 0}
      <h4>Children</h4>
      <ul class="graph-links">
        {#each children as link (link.path)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to child {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if siblings.length > 0}
      <h4>Siblings</h4>
      <ul class="graph-links">
        {#each siblings as link (link.path)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to sibling {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if outgoing.length > 0}
      <h4>Outgoing references and includes</h4>
      <ul class="graph-links">
        {#each outgoing as link (`${link.kind}:${link.path}`)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if backlinks.length > 0}
      <h4>Backlinks</h4>
      <ul class="graph-links">
        {#each backlinks as link (`back:${link.kind}:${link.path}`)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to backlink {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if relations.length > 0}
      <h4>Relations from completion.json</h4>
      <ul class="graph-links">
        {#each relations as relation (`${relation.kind}:${relation.target}`)}
          <li>
            {#if nodeForIdLocal(relation.target)}
              <button type="button" onclick={() => onOpenNode(nodeForIdLocal(relation.target))}>
                Go to {relation.kind} {relation.target}
              </button>
            {:else}
              <span>{relation.kind} {relation.target}</span>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
    {#if wikiLinks.length > 0}
      <h4>Wiki links in this buffer</h4>
      <ul class="graph-links">
        {#each wikiLinks as link (link.id)}
          <li>
            {#if link.node}
              <button type="button" onclick={() => onOpenNode(link.node)}>Go to wiki link {link.id}</button>
            {:else}
              <span>Unresolved wiki link {link.id}</span>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  {:else if graph.payload?.graph}
    {#if buffer.activePath}
      <p>This file is not a page in the Boris graph.</p>
    {:else}
      <p>Select a node to open a page, or pick a file from Project files.</p>
    {/if}
  {/if}
</section>
