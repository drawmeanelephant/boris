<script lang="ts">
	import type { ForestItem } from '$lib/boris/graph';

	let {
		forest,
		currentId
	}: {
		forest: ForestItem[];
		currentId?: string;
	} = $props();

	function link(id: string) {
		return `/${id}`;
	}

	function titleOf(id: string, title: string | null) {
		return title ?? id;
	}
</script>

<nav class="site-nav" aria-label="Boris entities">
	{#if forest.length === 0}
		<p class="nav-empty">No trunks — run <code>npm run data</code>.</p>
	{/if}
	<ul>
		{#each forest as trunk (trunk.node.id)}
			<li>
				<a
					href={link(trunk.node.id)}
					class:is-current={currentId === trunk.node.id}
					aria-current={currentId === trunk.node.id ? 'page' : undefined}
				>
					{titleOf(trunk.node.id, trunk.node.title)}
				</a>
				{#if trunk.children.length > 0}
					<ul>
						{#each trunk.children as child (child.id)}
							<li>
								<a
									href={link(child.id)}
									class:is-current={currentId === child.id}
									aria-current={currentId === child.id ? 'page' : undefined}
								>
									{titleOf(child.id, child.title)}
								</a>
							</li>
						{/each}
					</ul>
				{/if}
			</li>
		{/each}
	</ul>
</nav>
