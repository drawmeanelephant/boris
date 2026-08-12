<script lang="ts">
	import EntitySearch, { type SearchItem } from '$lib/components/EntitySearch.svelte';
	import type { PageData } from './$types';
	let { data }: { data: PageData } = $props();

	const manifest = $derived(data.manifest);
	const forest = $derived(data.forest);

	const items: SearchItem[] = $derived(forest.flatMap((trunk) => {
		const trunkItem: SearchItem = {
			id: trunk.node.id,
			title: trunk.node.title,
			status: trunk.node.status,
			tags: trunk.node.tags,
			role: trunk.node.role,
			parentId: trunk.node.parent,
			childCount: trunk.children.length
		};
		const childItems: SearchItem[] = trunk.children.map((child) => ({
			id: child.id,
			title: child.title,
			status: child.status,
			tags: child.tags,
			role: child.role,
			parentId: child.parent,
			childCount: 0
		}));
		return [trunkItem, ...childItems];
	}));

	const totalSatellites = $derived(manifest.pages.filter((p) => p.role === 'satellite').length);
	const published = $derived(manifest.pages.filter((p) => p.status === 'published').length);
</script>

<svelte:head>
	<title>Svelte × Boris — index</title>
</svelte:head>

<h1>Boris content, rendered by Svelte</h1>

<p>
	Everything on this site comes from Boris-compiled artifacts: the
	<a href="/boris/manifest.json">IR manifest</a> and
	<a href="/boris/graph.json">graph</a> for structure, and Boris-rendered body
	fragments for content. Svelte owns presentation only — it never re-parses
	Markdown, re-resolves links, or re-derives the graph.
</p>

<dl class="meta">
	<div><dt>compiler</dt><dd><code>{manifest.compiler}</code></dd></div>
	<div><dt>IR schema</dt><dd><code>{manifest.schemaVersion}</code></dd></div>
	<div><dt>content root</dt><dd><code>{manifest.contentRoot}</code></dd></div>
	<div><dt>entities</dt><dd>{manifest.pageCount} ({forest.length} trunks, {totalSatellites} satellites)</dd></div>
	<div><dt>published</dt><dd>{published}</dd></div>
</dl>

<EntitySearch {items} />

<style>
	.meta {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(13rem, 1fr));
		gap: 0.6rem 1.5rem;
		border: 1px solid var(--border);
		border-radius: 10px;
		padding: 0.9rem 1.1rem;
		margin: 1rem 0;
		background: var(--surface);
	}
	.meta div {
		display: flex;
		gap: 0.5rem;
		align-items: baseline;
	}
	.meta dt {
		font-size: 0.75rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		opacity: 0.6;
	}
	.meta dd {
		margin: 0;
	}
</style>
