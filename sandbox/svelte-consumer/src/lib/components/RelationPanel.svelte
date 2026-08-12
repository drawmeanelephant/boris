<script lang="ts">
	import type { GraphNode } from '$lib/boris/types';
	import type { RelatedPage } from '$lib/boris/graph';

	let {
		node,
		parent,
		children,
		siblings,
		incoming,
		outgoing,
		includes
	}: {
		node: GraphNode;
		parent: GraphNode | null;
		children: GraphNode[];
		siblings: GraphNode[];
		incoming: RelatedPage[];
		outgoing: RelatedPage[];
		includes: string[];
	} = $props();

	function link(id: string) {
		return `/${id}`;
	}

	function titleOf(id: string, title: string | null) {
		return title ?? id;
	}
</script>

<aside class="relations" aria-label="Graph relations">
	<h2>In the Boris graph</h2>

	{#if parent}
		<section>
			<h3>Satellite of</h3>
			<ul>
				<li><a href={link(parent.id)}>{titleOf(parent.id, parent.title)}</a></li>
			</ul>
		</section>
	{/if}

	{#if children.length > 0}
		<section>
			<h3>Children</h3>
			<ul>
				{#each children as child (child.id)}
					<li><a href={link(child.id)}>{titleOf(child.id, child.title)}</a></li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if siblings.length > 0}
		<section>
			<h3>Peers under {parent ? titleOf(parent.id, parent.title) : ''}</h3>
			<ul>
				{#each siblings as sib (sib.id)}
					<li><a href={link(sib.id)}>{titleOf(sib.id, sib.title)}</a></li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if outgoing.length > 0}
		<section>
			<h3>References</h3>
			<ul>
				{#each outgoing as rel (rel.node.id)}
					<li><a href={link(rel.node.id)}>{titleOf(rel.node.id, rel.node.title)}</a></li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if incoming.length > 0}
		<section>
			<h3>Referenced from</h3>
			<ul>
				{#each incoming as rel (rel.node.id)}
					<li><a href={link(rel.node.id)}>{titleOf(rel.node.id, rel.node.title)}</a></li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if includes.length > 0}
		<section>
			<h3>Includes</h3>
			<ul>
				{#each includes as src (src)}
					<li><code>{src}</code></li>
				{/each}
			</ul>
		</section>
	{/if}

	{#if !parent && children.length === 0 && siblings.length === 0 && outgoing.length === 0 && incoming.length === 0 && includes.length === 0}
		<p class="empty">No graph relations for this entity.</p>
	{/if}
</aside>

<style>
	.relations {
		font-size: 0.85rem;
		border-top: 1px solid var(--border);
		margin-top: 2rem;
		padding-top: 1rem;
		display: grid;
		gap: 0.75rem;
	}
	.relations h2 {
		font-size: 0.8rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		opacity: 0.6;
		margin: 0;
	}
	.relations section {
		display: grid;
		gap: 0.25rem;
	}
	.relations h3 {
		font-size: 0.75rem;
		margin: 0;
		opacity: 0.75;
	}
	.relations ul {
		list-style: none;
		margin: 0;
		padding: 0;
		display: flex;
		flex-wrap: wrap;
		gap: 0.35rem;
	}
	.relations a {
		display: inline-block;
		border: 1px solid var(--border);
		border-radius: 999px;
		padding: 0.15rem 0.6rem;
		text-decoration: none;
		color: inherit;
	}
	.relations a:hover {
		background: var(--surface);
	}
	.empty {
		opacity: 0.6;
		margin: 0;
	}
</style>
