<script lang="ts">
  import type { GraphDocument, GraphLink, GraphNode } from '../lib/types';

  let {
    activeNode,
    parentNode,
    graphChildren,
    graphSiblings,
    graphOutgoing,
    graphBacklinks,
    graphRelations,
    bufferWikiLinks,
    graphStatus,
    graphPayload,
    commandRunning,
    onOpenPath,
    onOpenNode,
    onImpact
  }: {
    activeNode: GraphNode | null;
    parentNode: GraphNode | null;
    graphChildren: GraphLink[];
    graphSiblings: GraphLink[];
    graphOutgoing: GraphLink[];
    graphBacklinks: GraphLink[];
    graphRelations: Array<{ kind: string; target: string }>;
    bufferWikiLinks: Array<{ id: string; node: GraphNode | null }>;
    graphStatus: string;
    graphPayload: { graph: GraphDocument | null } | null;
    commandRunning: boolean;
    onOpenPath: (path: string) => void;
    onOpenNode: (node: GraphNode | null) => void;
    onImpact: () => void;
  } = $props();

  function nodeForIdLocal(id: string): GraphNode | null {
    if (!graphPayload?.graph) return null;
    return graphPayload.graph.nodes.find((n) => n.id === id) ?? null;
  }
</script>

<section id="graph" class="graph-pane" aria-labelledby="graph-heading">
  <div class="problems-heading">
    <div>
      <h3 id="graph-heading">Graph</h3>
      <p>Read-only view of Boris <code>graph.json</code> and <code>completion.json</code>.</p>
    </div>
  </div>
  <p role="status" aria-label="Graph status" aria-live="polite">{graphStatus}</p>
  {#if activeNode}
    <p class="graph-current">{activeNode.id}{activeNode.title ? ` · ${activeNode.title}` : ''} · {activeNode.role}{activeNode.status ? ` · ${activeNode.status}` : ''}</p>
    <div class="graph-actions" aria-label="Graph navigation">
      {#if parentNode}
        <button type="button" onclick={() => onOpenNode(parentNode)}>Go to parent {parentNode.id}</button>
      {/if}
      <button type="button" disabled={commandRunning} onclick={onImpact}>Run impact on {activeNode.id}</button>
    </div>
    {#if graphChildren.length > 0}
      <h4>Children</h4>
      <ul class="graph-links">
        {#each graphChildren as link (link.path)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to child {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if graphSiblings.length > 0}
      <h4>Siblings</h4>
      <ul class="graph-links">
        {#each graphSiblings as link (link.path)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to sibling {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if graphOutgoing.length > 0}
      <h4>Outgoing references and includes</h4>
      <ul class="graph-links">
        {#each graphOutgoing as link (`${link.kind}:${link.path}`)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if graphBacklinks.length > 0}
      <h4>Backlinks</h4>
      <ul class="graph-links">
        {#each graphBacklinks as link (`back:${link.kind}:${link.path}`)}
          <li><button type="button" onclick={() => onOpenPath(link.path)}>Go to backlink {link.label}</button></li>
        {/each}
      </ul>
    {/if}
    {#if graphRelations.length > 0}
      <h4>Relations from completion.json</h4>
      <ul class="graph-links">
        {#each graphRelations as relation (`${relation.kind}:${relation.target}`)}
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
    {#if bufferWikiLinks.length > 0}
      <h4>Wiki links in this buffer</h4>
      <ul class="graph-links">
        {#each bufferWikiLinks as link (link.id)}
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
  {:else if graphPayload?.graph}
    <p>This file is not a page in the Boris graph.</p>
  {/if}
</section>
