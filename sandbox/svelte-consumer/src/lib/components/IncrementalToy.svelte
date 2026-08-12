<script lang="ts">
	// IncrementalToy — a microscopic incremental-game-shaped widget.
	//
	// BOUNDARY RULE: Boris owns knowledge; Svelte owns interaction. This
	// component is pure browser-owned state: it never parses Boris sources,
	// never reads Boris relations or schemas, and never invents identities.
	// The only Boris-derived input is `entityId`, used OPACELY as a storage
	// key (no new identity system — the canonical Boris id already exists).
	//
	// Persistence: localStorage only, so state is browser-local. It survives
	// SvelteKit navigation and page reload, and it is destroyed when the
	// storage is cleared. This is deliberately NOT a Boris concept.
	import { onMount } from 'svelte';

	let { entityId }: { entityId: string } = $props();

	const storageKey = () => `boris-spike:incremental:${entityId}`;

	let resource = $state(0);
	let perClick = $state(1);
	let upgradeCost = $state(10);
	let ready = $state(false); // SSR-safe: never touch localStorage before mount

	onMount(() => {
		try {
			const raw = localStorage.getItem(storageKey());
			if (raw) {
				const saved = JSON.parse(raw) as { resource?: number; perClick?: number; upgradeCost?: number };
				if (typeof saved.resource === 'number') resource = saved.resource;
				if (typeof saved.perClick === 'number') perClick = saved.perClick;
				if (typeof saved.upgradeCost === 'number') upgradeCost = saved.upgradeCost;
			}
		} catch {
			// storage unavailable / corrupt — start fresh
		}
		ready = true;
	});

	// Persist on every change, but only after the initial load so we never
	// clobber saved state with defaults.
	$effect(() => {
		if (!ready) return;
		try {
			localStorage.setItem(
				storageKey(),
				JSON.stringify({ resource, perClick, upgradeCost })
			);
		} catch {
			// quota / privacy mode — the widget still works in-memory
		}
	});

	function gather() {
		resource += perClick;
	}

	function buyUpgrade() {
		if (resource >= upgradeCost) {
			resource -= upgradeCost;
			perClick += 2;
			upgradeCost = Math.ceil(upgradeCost * 2.0); // Experiment 4b: cost curve changed
		}
	}

	function reset() {
		resource = 0;
		perClick = 1;
		upgradeCost = 10;
	}
</script>

<section class="toy" aria-label="Incremental toy (browser state)">
	<h2>Svelte interactive overlay (v2)</h2>
	<p class="toy-note">
		Browser-owned state beside Boris content. Persisted in
		<code>localStorage</code> under an opaque key derived from the entity id
		(<code>{entityId}</code>). Boris knows nothing about this widget.
	</p>

	<div class="toy-row">
		<output class="resource" aria-live="polite">resource: {resource}</output>
		<button onclick={gather}>Gather (+{perClick})</button>
	</div>

	<div class="toy-row">
		<button onclick={buyUpgrade} disabled={resource < upgradeCost}>
			Upgrade: {upgradeCost} resource → +2 per click
		</button>
		<button class="reset" onclick={reset}>reset</button>
	</div>
</section>

<style>
	.toy {
		margin: 2rem 0 0;
		padding: 1rem 1.25rem;
		border: 1px dashed var(--accent);
		border-radius: 10px;
		background: color-mix(in srgb, var(--surface) 60%, transparent);
	}
	.toy h2 {
		font-size: 0.9rem;
		text-transform: uppercase;
		letter-spacing: 0.05em;
		margin: 0 0 0.5rem;
		opacity: 0.75;
	}
	.toy-note {
		font-size: 0.8rem;
		opacity: 0.7;
		margin: 0 0 0.75rem;
	}
	.toy-row {
		display: flex;
		flex-wrap: wrap;
		align-items: center;
		gap: 0.75rem;
		margin: 0.5rem 0;
	}
	.resource {
		font-weight: 700;
		font-variant-numeric: tabular-nums;
		min-width: 8rem;
	}
	.toy button {
		border: 1px solid var(--border);
		background: var(--surface);
		color: var(--text);
		border-radius: 8px;
		padding: 0.4rem 0.8rem;
		font: inherit;
		font-size: 0.85rem;
		cursor: pointer;
	}
	.toy button:disabled {
		opacity: 0.45;
		cursor: not-allowed;
	}
	.toy button:not(:disabled):hover {
		border-color: var(--accent);
	}
	.toy .reset {
		opacity: 0.6;
		font-size: 0.75rem;
	}
</style>
