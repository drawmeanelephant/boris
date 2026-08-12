<script lang="ts">
	import { page } from '$app/state';
</script>

<svelte:head>
	<title>{page.status} · Svelte × Boris</title>
</svelte:head>

<h1>{page.status}</h1>
<p>{page.error?.message ?? 'Something went wrong.'}</p>
<p>
	<a href="/">Back to the index</a>
</p>
