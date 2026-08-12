<script lang="ts">
	import RelationPanel from '$lib/components/RelationPanel.svelte';
	import IncrementalToy from '$lib/components/IncrementalToy.svelte';
	import type { PageData } from './$types';
	let { data }: { data: PageData } = $props();

	// $derived so values follow the prop across client-side navigation between
	// detail pages (the [...id] component instance is reused by the router).
	const node = $derived(data.node);
	const body = $derived(data.body);
	const breadcrumb = $derived(data.breadcrumb);
	const parent = $derived(data.parent);
	const children = $derived(data.children);
	const siblings = $derived(data.siblings);
	const incoming = $derived(data.incoming);
	const outgoing = $derived(data.outgoing);
	const includes = $derived(data.includes);
	const title = $derived(node.title ?? node.id);
</script>

<svelte:head>
	<title>{title} · Svelte × Boris</title>
</svelte:head>

<nav class="breadcrumb" aria-label="Breadcrumb">
	{#each breadcrumb as crumb, i (crumb.id)}
		{#if i < breadcrumb.length - 1}
			<a href="/{crumb.id}">{crumb.title ?? crumb.id}</a>
		{:else}
			<span aria-current="page">{crumb.title ?? crumb.id}</span>
		{/if}
	{/each}
</nav>

<header class="page-head">
	<h1>{title}</h1>
	<div class="chips">
		<span class="chip chip-role">{node.role}</span>
		{#if node.status}<span class="chip chip-status chip-{node.status}">{node.status}</span>{/if}
		{#each node.tags as tag (tag)}<span class="chip chip-tag">{tag}</span>{/each}
	</div>
	<p class="provenance">
		entity id <code>{node.id}</code> · source <code>{node.sourcePath}</code> · index {node.index}
	</p>
</header>

{#if body !== null}
	<div class="body">{@html body}</div>
{:else}
	<div class="missing">
		<p>No body fragment found for this entity. Run <code>npm run data</code> to generate
			<code>data/bodies/{node.id}.html</code>.</p>
	</div>
{/if}

<!-- {#key} remounts the widget when navigating between entities so each
     page's browser state loads fresh from localStorage (Experiment 2). -->
{#key node.id}
	<IncrementalToy entityId={node.id} />
{/key}

<RelationPanel {node} {parent} {children} {siblings} {incoming} {outgoing} {includes} />

<style>
	.breadcrumb {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
		font-size: 0.85rem;
		opacity: 0.8;
		margin-bottom: 0.75rem;
	}
	.breadcrumb a {
		color: inherit;
	}
	.breadcrumb span::before,
	.breadcrumb a:not(:first-child)::before {
		content: '/';
		margin-right: 0.4rem;
		opacity: 0.5;
	}
	.chips {
		display: flex;
		flex-wrap: wrap;
		gap: 0.4rem;
		margin: 0.75rem 0 0.25rem;
	}
	.chip {
		font-size: 0.72rem;
		border: 1px solid var(--border);
		border-radius: 999px;
		padding: 0.15rem 0.6rem;
	}
	.chip-status {
		font-weight: 600;
	}
	.chip-published {
		border-color: color-mix(in srgb, #2a8 60%, transparent);
		color: #1a6;
	}
	.chip-draft {
		border-color: color-mix(in srgb, #c80 60%, transparent);
		color: #a70;
	}
	.provenance {
		font-size: 0.8rem;
		opacity: 0.65;
		margin: 0.25rem 0 1rem;
	}
	.missing {
		border: 1px dashed var(--border);
		border-radius: 8px;
		padding: 1rem;
		opacity: 0.8;
	}
</style>
