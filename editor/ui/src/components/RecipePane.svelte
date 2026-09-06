<script lang="ts">
  import type { GraphNode } from '../lib/types';
  import { displayQuantity, escapeHtml, quantityLabel } from '../lib/utils';
  import { graph, activeNode } from '../lib/state/graph.svelte';
  import { problems, visibleScaleView } from '../lib/state/problems.svelte';
  import { buffer } from '../lib/state/buffer.svelte';

  let {
    onScale,
    onReset,
    onOpenNode
  }: {
    onScale: () => void;
    onReset: () => void;
    onOpenNode: (node: GraphNode | null) => void;
  } = $props();

  const node = $derived(activeNode());
  const scaleView = $derived(visibleScaleView());

  function nodeForIdLocal(id: string): GraphNode | null {
    if (!graph.payload?.graph) return null;
    return graph.payload.graph.nodes.find((n) => n.id === id) ?? null;
  }

  // Read-only Boris recipe facet printout. Quantities are author strings;
  // the print window is a static presentation of the open node's facet.
  function printRecipe() {
    if (!node?.recipe) return;
    const recipe = node.recipe;
    const title = node.title ?? node.id;
    const rows = (items: Array<{ name: string; extra?: string; qty: string }>) =>
      items.map(item => `<tr><td>${escapeHtml(item.name)}</td><td>${escapeHtml(item.qty)}</td><td>${escapeHtml(item.extra ?? '')}</td></tr>`).join('');
    const html = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>${escapeHtml(title)}</title>
<style>body{font:16px/1.45 ui-serif,Georgia,serif;margin:1.5rem;color:#17201d}h1{font-size:1.6rem}table{width:100%;border-collapse:collapse;margin:0 0 1.25rem}th,td{text-align:left;padding:.35rem .4rem;border-bottom:1px solid #ccd6cf}p.note{color:#53625c;font-size:.9rem}</style>
</head><body>
<h1>${escapeHtml(title)}</h1>
<p class="note">Read-only Boris recipe facet. Quantities are author strings. Scale recipe asks Boris; it does not rewrite the .cook file.</p>
<h2>Ingredients</h2>
<table><thead><tr><th>Name</th><th>Quantity</th><th>Preparation / recipe</th></tr></thead><tbody>
${rows(recipe.ingredients.map(item => ({ name: item.name, qty: quantityLabel(item.quantity), extra: item.recipeRef ? `recipe ${item.recipeRef}` : item.preparation })))}
</tbody></table>
<h2>Cookware</h2>
<table><thead><tr><th>Name</th><th>Quantity</th><th></th></tr></thead><tbody>
${rows(recipe.cookware.map(item => ({ name: item.name, qty: quantityLabel(item.quantity) })))}
</tbody></table>
<h2>Timers</h2>
<table><thead><tr><th>Name</th><th>Quantity</th><th></th></tr></thead><tbody>
${rows(recipe.timers.map(item => ({ name: item.name || 'timer', qty: quantityLabel(item.quantity) })))}
</tbody></table>
</body></html>`;
    const printer = window.open('', 'boris-recipe-print');
    if (!printer) {
      buffer.editorStatus = 'Could not open the recipe print view. Allow pop-ups for this local editor.';
      return;
    }
    printer.document.open();
    printer.document.write(html);
    printer.document.close();
    printer.focus();
    printer.print();
  }
</script>

{#if node?.recipe}
  <section class="recipe-pane" aria-labelledby="recipe-heading">
    <div class="problems-heading">
      <div>
        <h3 id="recipe-heading">Recipe</h3>
        <p>Read-only Boris <code>recipe</code> facet. Source remains the <code>.cook</code> file. Scale recipe asks the compiler; it does not write quantities back.</p>
      </div>
      <button type="button" onclick={printRecipe}>Print this recipe</button>
    </div>
    <div class="recipe-scale">
      <label>
        Scale factor
        <input type="text" name="scale-factor" value={problems.scaleFactor} oninput={(e) => (problems.scaleFactor = (e.currentTarget as HTMLInputElement).value)} autocomplete="off" />
      </label>
      <button type="button" disabled={problems.running} onclick={onScale}>Scale recipe</button>
      <button type="button" disabled={scaleView === null} onclick={onReset}>Reset scale</button>
    </div>
    <h4>Ingredients</h4>
    <table class="recipe-table">
      <thead><tr><th>Name</th><th>Quantity</th><th>Preparation</th><th>Recipe reference</th></tr></thead>
      <tbody>
        {#each node.recipe.ingredients as ingredient, ingredientIndex (`${ingredient.name}-${ingredientIndex}`)}
          <tr>
            <td>{ingredient.name}</td>
            <td>{displayQuantity(ingredient.quantity, scaleView?.ingredients[ingredientIndex]?.quantity, false)}</td>
            <td>{ingredient.preparation || '—'}</td>
            <td>
              {#if ingredient.recipeRef && nodeForIdLocal(ingredient.recipeRef)}
                <button type="button" onclick={() => onOpenNode(nodeForIdLocal(ingredient.recipeRef!))}>
                  Go to recipe {ingredient.recipeRef}
                </button>
              {:else if ingredient.recipeRef}
                {ingredient.recipeRef}
              {:else}
                —
              {/if}
            </td>
          </tr>
        {/each}
      </tbody>
    </table>
    <h4>Cookware</h4>
    <table class="recipe-table">
      <thead><tr><th>Name</th><th>Quantity</th></tr></thead>
      <tbody>
        {#each node.recipe.cookware as item, itemIndex (`cookware-${item.name}-${itemIndex}`)}
          <tr><td>{item.name}</td><td>{displayQuantity(item.quantity, scaleView?.cookware[itemIndex]?.quantity, false)}</td></tr>
        {/each}
      </tbody>
    </table>
    <h4>Timers</h4>
    <table class="recipe-table">
      <thead><tr><th>Name</th><th>Quantity</th></tr></thead>
      <tbody>
        {#each node.recipe.timers as timer, timerIndex (`timer-${timer.name}-${timerIndex}`)}
          <tr><td>{timer.name || 'timer'}</td><td>{displayQuantity(timer.quantity, scaleView?.timers[timerIndex]?.quantity, true)}</td></tr>
        {/each}
      </tbody>
    </table>
  </section>
{/if}
