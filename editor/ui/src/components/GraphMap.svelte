<script lang="ts">
  // Visual map of the frozen Boris graph for the Graph pane.
  //
  // This is a review aid, not a navigation surface: the whole SVG is
  // `aria-hidden` and no workflow depends on it. Every target it exposes is
  // also reachable from the Graph pane's semantic lists below, which remain
  // the keyboard path (the editor's accessibility contract). Pointer clicks
  // are a convenience on top.
  import type { GraphDocument, GraphNode } from '../lib/types';
  import { MAP_DEPTH_GAP, MAP_NODE_HEIGHT, layoutGraphMap, type GraphMapEdge } from '../lib/graph-map';

  let {
    graph,
    activeId,
    onOpenNode
  }: {
    graph: GraphDocument;
    activeId: string | null;
    onOpenNode: (node: GraphNode) => void;
  } = $props();

  const layout = $derived(layoutGraphMap(graph));
  const nodesById = $derived(new Map(graph.nodes.map((node) => [node.id, node])));

  function edgePath(edge: GraphMapEdge): string {
    const fromBottom = edge.from.y + MAP_NODE_HEIGHT / 2;
    const toTop = edge.to.y - MAP_NODE_HEIGHT / 2;
    if (edge.kind === 'parent') {
      const midY = fromBottom + (toTop - fromBottom) / 2;
      return `M ${edge.from.x} ${fromBottom} C ${edge.from.x} ${midY}, ${edge.to.x} ${midY}, ${edge.to.x} ${toTop}`;
    }
    if (Math.abs(edge.to.y - edge.from.y) < 1) {
      // Same rank: bow the reference below both nodes.
      return `M ${edge.from.x} ${fromBottom} C ${edge.from.x} ${fromBottom + 46}, ${edge.to.x} ${toTop + 46}, ${edge.to.x} ${toTop}`;
    }
    if (edge.to.y > edge.from.y) {
      const midY = fromBottom + (toTop - fromBottom) / 2;
      return `M ${edge.from.x} ${fromBottom} C ${edge.from.x} ${midY}, ${edge.to.x} ${midY}, ${edge.to.x} ${toTop}`;
    }
    // Upward reference: leave and arrive over the tops.
    const fromTop = edge.from.y - MAP_NODE_HEIGHT / 2;
    const toTopUp = edge.to.y - MAP_NODE_HEIGHT / 2;
    const midY = toTopUp - MAP_DEPTH_GAP / 2;
    return `M ${edge.from.x} ${fromTop} C ${edge.from.x} ${midY}, ${edge.to.x} ${midY}, ${edge.to.x} ${toTopUp}`;
  }

  function weightStroke(weight: number): number {
    return 1 + Math.min(weight, 6) * 0.5;
  }

  function open(id: string) {
    const node = nodesById.get(id);
    if (node) onOpenNode(node);
  }
</script>

<figure class="graph-map" data-testid="graph-map">
  <div class="graph-map-scroll">
    <svg
      viewBox={`0 0 ${layout.width} ${layout.height}`}
      width={layout.width}
      height={layout.height}
      preserveAspectRatio="xMidYMin meet"
      aria-hidden="true"
      focusable="false"
      role="presentation"
    >
      <g class="graph-map-edges">
        {#each layout.edges as edge, index (index)}
          <path class:graph-map-edge--reference={edge.kind === 'reference'} class="graph-map-edge" d={edgePath(edge)} />
        {/each}
      </g>
      <g class="graph-map-nodes">
        {#each layout.nodes as item (item.id)}
          <!-- The whole SVG is aria-hidden and the Graph pane's lists below
               are the keyboard path; click-to-open on the visual aid is a
               deliberate pointer-only convenience, never a required flow. -->
          <!-- svelte-ignore a11y_click_events_have_key_events -->
          <g
            class="graph-map-node"
            role="presentation"
            class:graph-map-node--trunk={item.role === 'trunk'}
            class:graph-map-node--satellite={item.role === 'satellite'}
            class:graph-map-node--active={item.id === activeId}
            data-node-id={item.id}
            transform={`translate(${item.x}, ${item.y})`}
            onclick={() => open(item.id)}
          >
            <title>{item.id}</title>
            <rect
              x={-item.width / 2}
              y={-item.height / 2}
              width={item.width}
              height={item.height}
              rx="6"
              stroke-width={weightStroke(item.weight)}
            />
            <text x="0" y="4" text-anchor="middle">{item.label}</text>
          </g>
        {/each}
      </g>
    </svg>
  </div>
  <figcaption class="graph-map-caption">
    Visual map of <code>graph.json</code> — select a page to open it. The lists below are the keyboard path.
  </figcaption>
</figure>
