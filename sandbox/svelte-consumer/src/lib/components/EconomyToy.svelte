<script lang="ts">
	// EconomyToy — a two-resource economy widget with passive ticks (round 3).
	//
	// BOUNDARY RULE: Boris owns knowledge; Svelte owns interaction. This
	// component is pure browser-owned state: it never parses Boris sources,
	// never reads Boris relations or schemas, and never invents identities.
	// The only Boris-derived input is `entityId`, used OPACELY as a storage
	// key (no new identity system — the canonical Boris id already exists).
	//
	// Heavier than the round-2 IncrementalToy on purpose: two interdependent
	// resources, a wall-clock production ticker, offline catch-up from the
	// last-saved timestamp, and cross-resource upgrade costs. Still entirely
	// a Svelte concern — Boris is not involved in any of it.
	//
	// Persistence: localStorage only, browser-local. State survives SvelteKit
	// navigation and page reload; production accrues while the widget is
	// mounted (ticks) and is caught up from wall-clock time on remount.
	// Deliberately NOT a Boris concept.
	import { onMount, onDestroy } from 'svelte';

	let { entityId }: { entityId: string } = $props();

	const storageKey = () => `boris-spike:economy:${entityId}`;
	const TICK_MS = 1000;
	const MAX_OFFLINE_TICKS = 3600; // catch up at most 1h of production

	let wood = $state(0);
	let stone = $state(0);
	let axeLevel = $state(0); // +1 wood/tick per level
	let pickLevel = $state(0); // +1 stone/tick per level
	let ready = $state(false); // SSR-safe: never touch localStorage before mount

	const woodRate = $derived(1 + axeLevel);
	const stoneRate = $derived(1 + pickLevel);
	// Cross-resource costs: the axe is paid in stone, the pickaxe in wood, so
	// the two resources genuinely interact instead of being independent bars.
	const axeCost = $derived(Math.ceil(10 * Math.pow(1.6, axeLevel)));
	const pickCost = $derived(Math.ceil(10 * Math.pow(1.6, pickLevel)));

	let timer: ReturnType<typeof setInterval> | undefined;

	onMount(() => {
		try {
			const raw = localStorage.getItem(storageKey());
			if (raw) {
				const saved = JSON.parse(raw) as {
					v?: number;
					wood?: number;
					stone?: number;
					axeLevel?: number;
					pickLevel?: number;
					savedAt?: number;
				};
				if (typeof saved.wood === 'number') wood = saved.wood;
				if (typeof saved.stone === 'number') stone = saved.stone;
				if (typeof saved.axeLevel === 'number') axeLevel = saved.axeLevel;
				if (typeof saved.pickLevel === 'number') pickLevel = saved.pickLevel;
				// Offline catch-up: accrue production for wall-clock time away,
				// capped so long absences don't produce absurd numbers.
				if (typeof saved.savedAt === 'number' && Number.isFinite(saved.savedAt)) {
					const elapsed = Math.max(0, (Date.now() - saved.savedAt) / TICK_MS);
					const ticks = Math.min(MAX_OFFLINE_TICKS, Math.floor(elapsed));
					wood += (1 + axeLevel) * ticks;
					stone += (1 + pickLevel) * ticks;
				}
			}
		} catch {
			// storage unavailable / corrupt — start fresh
		}
		ready = true;
		timer = setInterval(tick, TICK_MS);
	});

	onDestroy(() => {
		if (timer !== undefined) clearInterval(timer);
	});

	// Passive production while the widget is mounted.
	function tick() {
		wood += 1 + axeLevel;
		stone += 1 + pickLevel;
	}

	// Manual gather (flat, independent of upgrades).
	function chop() {
		wood += 2;
	}
	function mine() {
		stone += 2;
	}

	function buyAxe() {
		if (stone >= axeCost) {
			stone -= axeCost;
			axeLevel += 1;
		}
	}
	function buyPick() {
		if (wood >= pickCost) {
			wood -= pickCost;
			pickLevel += 1;
		}
	}

	function reset() {
		wood = 0;
		stone = 0;
		axeLevel = 0;
		pickLevel = 0;
	}

	// Persist on every change, but only after the initial load so we never
	// clobber saved state with defaults. savedAt doubles as the offline
	// catch-up anchor for the next mount.
	$effect(() => {
		if (!ready) return;
		try {
			localStorage.setItem(
				storageKey(),
				JSON.stringify({ v: 1, wood, stone, axeLevel, pickLevel, savedAt: Date.now() })
			);
		} catch {
			// quota / privacy mode — the widget still works in-memory
		}
	});
</script>

<section class="toy" aria-label="Economy toy (browser state)">
	<h2>Svelte interactive overlay (v3)</h2>
	<p class="toy-note">
		Browser-owned state beside Boris content: a two-resource economy with
		passive ticks. Persisted in <code>localStorage</code> under an opaque
		key derived from the entity id (<code>{entityId}</code>). Boris knows
		nothing about this widget.
	</p>

	<div class="toy-grid">
		<div class="toy-cell">
			<output class="resource" aria-live="polite">wood: {wood}</output>
			<span class="rate">+{woodRate}/tick</span>
			<button onclick={chop}>Chop (+2)</button>
		</div>
		<div class="toy-cell">
			<output class="resource" aria-live="polite">stone: {stone}</output>
			<span class="rate">+{stoneRate}/tick</span>
			<button onclick={mine}>Mine (+2)</button>
		</div>
	</div>

	<div class="toy-row">
		<button onclick={buyAxe} disabled={stone < axeCost}>
			Axe: {axeCost} stone → +1 wood/tick
		</button>
		<button onclick={buyPick} disabled={wood < pickCost}>
			Pickaxe: {pickCost} wood → +1 stone/tick
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
	.toy-grid {
		display: grid;
		grid-template-columns: repeat(auto-fit, minmax(13rem, 1fr));
		gap: 0.75rem;
		margin: 0.5rem 0;
	}
	.toy-cell {
		display: flex;
		flex-direction: column;
		gap: 0.4rem;
		padding: 0.6rem 0.75rem;
		border: 1px solid var(--border);
		border-radius: 8px;
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
	}
	.rate {
		font-size: 0.75rem;
		opacity: 0.6;
		font-variant-numeric: tabular-nums;
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
