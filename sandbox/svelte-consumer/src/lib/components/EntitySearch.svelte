<script lang="ts">
	// Interactive search/filter for the index page. This component is
	// deliberately UNRELATED to Boris semantics: it is presentational Svelte
	// (local state, filtering, chips) that happens to consume Boris-shaped
	// data. It exists to prove rich client UI can coexist with Boris-managed
	// content without any framework knowledge leaking into Boris.
	export interface SearchItem {
		id: string;
		title: string | null;
		status: string | null;
		tags: string[];
		role: 'trunk' | 'satellite';
		parentId: string | null;
		childCount: number;
	}

	let {
		items
	}: {
		items: SearchItem[];
	} = $props();

	let query = $state('');
	let activeTags = $state<Set<string>>(new Set());

	const allTags = $derived(
		[...new Set(items.flatMap((i) => i.tags))].sort((a, b) => a.localeCompare(b))
	);

	const filtered = $derived.by(() => {
		const q = query.trim().toLowerCase();
		return items.filter((i) => {
			if (activeTags.size > 0 && ![...i.tags].some((t) => activeTags.has(t))) return false;
			if (!q) return true;
			return (
				i.id.toLowerCase().includes(q) ||
				(i.title ?? '').toLowerCase().includes(q) ||
				i.tags.some((t) => t.toLowerCase().includes(q))
			);
		});
	});

	// Pure derived (no side effects): safe to read in the template before
	// `filtered` is first evaluated.
	const resultCount = $derived(filtered.length);

	function toggleTag(tag: string) {
		const next = new Set(activeTags);
		if (next.has(tag)) {
			next.delete(tag);
		} else {
			next.add(tag);
		}
		activeTags = next;
	}

	function clear() {
		query = '';
		activeTags = new Set();
	}

</script>

<div class="search">
	<div class="search-row">
		<input
			type="search"
			bind:value={query}
			placeholder="Filter by title, id, or tag…"
			aria-label="Filter entities"
		/>
		{#if query || activeTags.size > 0}
			<button class="clear" onclick={clear} aria-label="Clear filters">clear</button>
		{/if}
		<span class="count" aria-live="polite">{resultCount} / {items.length}</span>
	</div>
	<div class="tags">
		{#each allTags as tag (tag)}
			<button
				class="tag"
				class:active={activeTags.has(tag)}
				onclick={() => toggleTag(tag)}
				aria-pressed={activeTags.has(tag)}
			>
				{tag}
			</button>
		{/each}
	</div>

	<ul class="results">
		{#each filtered as item (item.id)}
			<li>
				<a href="/{item.id}">
					<span class="result-title">{item.title ?? item.id}</span>
					<span class="result-id">{item.id}</span>
					{#if item.childCount > 0}<span class="chip">{item.childCount} satellite{item.childCount === 1 ? '' : 's'}</span>{/if}
					{#each item.tags as tag (tag)}<span class="chip chip-tag">{tag}</span>{/each}
				</a>
			</li>
		{:else}
			<li class="none">No entities match the current filters.</li>
		{/each}
	</ul>
</div>

<style>
	.search {
		display: grid;
		gap: 0.6rem;
		margin: 1rem 0 1.5rem;
	}
	.search-row {
		display: flex;
		align-items: center;
		gap: 0.5rem;
	}
	.search-row input {
		flex: 1;
		padding: 0.5rem 0.75rem;
		border: 1px solid var(--border);
		border-radius: 8px;
		background: var(--surface);
		color: var(--text);
		font: inherit;
	}
	.count {
		font-size: 0.8rem;
		opacity: 0.7;
		font-variant-numeric: tabular-nums;
	}
	.clear {
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		border-radius: 999px;
		padding: 0.25rem 0.6rem;
		font-size: 0.75rem;
		cursor: pointer;
	}
	.tags {
		display: flex;
		flex-wrap: wrap;
		gap: 0.35rem;
	}
	.tag {
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		border-radius: 999px;
		padding: 0.2rem 0.6rem;
		font-size: 0.75rem;
		cursor: pointer;
		transition: background 120ms, color 120ms;
	}
	.tag.active {
		background: var(--accent);
		border-color: var(--accent);
		color: #fff;
	}
	.results {
		list-style: none;
		margin: 0;
		padding: 0;
		display: grid;
		gap: 0.4rem;
	}
	.results a {
		display: flex;
		flex-wrap: wrap;
		align-items: baseline;
		gap: 0.5rem;
		padding: 0.55rem 0.75rem;
		border: 1px solid transparent;
		border-radius: 8px;
		text-decoration: none;
		color: inherit;
	}
	.results a:hover {
		background: var(--surface);
		border-color: var(--border);
	}
	.result-title {
		font-weight: 600;
	}
	.result-id {
		font-size: 0.8rem;
		opacity: 0.6;
		font-family: var(--mono);
	}
	.chip {
		font-size: 0.7rem;
		border: 1px solid var(--border);
		border-radius: 999px;
		padding: 0.05rem 0.45rem;
		opacity: 0.85;
	}
	.chip-tag {
		opacity: 0.6;
	}
	.none {
		padding: 1rem;
		text-align: center;
		opacity: 0.6;
	}
</style>
