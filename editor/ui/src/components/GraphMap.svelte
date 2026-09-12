<script lang="ts">
  // Visual map of the frozen Boris graph for the Graph pane.
  //
  // This is a review aid, not a navigation surface: the whole SVG is
  // `aria-hidden` and no workflow depends on it. Every target it exposes is
  // also reachable from the Graph pane's semantic lists below, which remain
  // the keyboard path (the editor's accessibility contract). Pointer clicks
  // are a convenience on top.
  //
  // Viewing is native: the viewport is a focusable scroll container (wheel,
  // touch, arrow keys), and visible zoom buttons scale the SVG through its
  // width/height so vectors stay crisp. No drag handler, no third party.
  import { tick } from 'svelte';
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

  const MIN_ZOOM = 0.05;
  const MAX_ZOOM = 3;
  const ZOOM_STEP = 1.25;

  let viewport = $state() as HTMLElement | undefined;
  let viewportWidth = $state(0);
  // null means "fit the width"; a number is an explicit user zoom. Keeping
  // fit as a mode (not a value) lets a container resize re-fit the map.
  let manualScale = $state<number | null>(null);

  const fitScale = $derived(viewportWidth > 0 ? Math.min(1, viewportWidth / layout.width) : 1);
  const scale = $derived(Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, manualScale ?? fitScale)));
  const zoomPercent = $derived(Math.round(scale * 100));

  // A new graph starts fit; previous zoom belonged to the previous picture.
  $effect(() => {
    void layout.width;
    manualScale = null;
  });

  $effect(() => {
    const element = viewport;
    if (!element) return;
    viewportWidth = element.clientWidth;
    const observer = new ResizeObserver((entries) => {
      for (const entry of entries) viewportWidth = entry.contentRect.width;
    });
    observer.observe(element);
    return () => observer.disconnect();
  });

  // Zoom around the visual center so the page under review stays put.
  async function applyZoom(next: number | null) {
    const element = viewport;
    const current = scale;
    const resolved = next === null ? fitScale : next;
    if (!element || resolved === current) {
      manualScale = next;
      return;
    }
    const centerX = (element.scrollLeft + element.clientWidth / 2) / current;
    const centerY = (element.scrollTop + element.clientHeight / 2) / current;
    manualScale = next;
    await tick();
    element.scrollLeft = centerX * scale - element.clientWidth / 2;
    element.scrollTop = centerY * scale - element.clientHeight / 2;
  }

  function zoomIn() {
    void applyZoom(Math.min(MAX_ZOOM, scale * ZOOM_STEP));
  }

  function zoomOut() {
    const next = scale / ZOOM_STEP;
    void applyZoom(next <= fitScale + 1e-6 ? null : next);
  }

  function fit() {
    void applyZoom(null);
  }

  function actualSize() {
    void applyZoom(1);
  }

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
  <div class="graph-map-controls" role="group" aria-label="Graph map zoom">
    <button type="button" onclick={zoomOut} disabled={manualScale === null && scale <= fitScale + 1e-6} aria-label="Zoom out">−</button>
    <span class="graph-map-zoom" data-testid="graph-map-zoom" aria-live="polite">{zoomPercent}%</span>
    <button type="button" onclick={zoomIn} disabled={scale >= MAX_ZOOM} aria-label="Zoom in">+</button>
    <button type="button" onclick={fit} disabled={manualScale === null} aria-label="Fit map to width">Fit</button>
    <button type="button" onclick={actualSize} disabled={Math.abs(scale - 1) < 1e-6} aria-label="Actual size (100%)">Actual size</button>
  </div>
  <!-- Focusable scroll container: a focused scrollable region pans with the
       arrow keys, which is the keyboard counterpart to the zoom buttons. -->
  <!-- svelte-ignore a11y_no_noninteractive_tabindex -->
  <div class="graph-map-scroll" bind:this={viewport} tabindex="0" role="region" aria-label="Graph map viewport">
    <svg
      viewBox={`0 0 ${layout.width} ${layout.height}`}
      width={layout.width * scale}
      height={layout.height * scale}
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
            class:graph-map-node--trunk={item.role === 'trunk'}
            class:graph-map-node--satellite={item.role === 'satellite'}
            class:graph-map-node--active={item.id === activeId}
            data-node-id={item.id}
            role="presentation"
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
