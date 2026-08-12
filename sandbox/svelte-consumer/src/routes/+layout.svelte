<script lang="ts">
	import '../app.css';
	import favicon from '$lib/assets/favicon.svg';
	import NavTree from '$lib/components/NavTree.svelte';
	import type { Snippet } from 'svelte';
	import { page } from '$app/state';
	import type { LayoutData } from './$types';

	let {
		children,
		data
	}: {
		children: Snippet;
		data: LayoutData;
	} = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
	<title>Svelte × Boris — consumer spike</title>
</svelte:head>

<div class="shell">
	<header class="brand">
		<a href="/">Svelte × Boris</a>
		<span class="brand-sub">consumer spike</span>
	</header>
	<NavTree forest={data.forest} currentId={page.route.id === '/[...id]' ? page.params.id : undefined} />
	<main class="content">{@render children()}</main>
</div>
