<script lang="ts">
  import type { GraphNode, RecipeScaleView } from '../lib/types';
  import { displayQuantity } from '../lib/utils';

  let {
    activeNode,
    scaleFactor,
    visibleScaleView,
    commandRunning,
    onFactorChange,
    onScale,
    onReset,
    onPrint,
    onOpenNode,
    graphPayload
  }: {
    activeNode: GraphNode | null;
    scaleFactor: string;
    visibleScaleView: RecipeScaleView | null;
    commandRunning: boolean;
    onFactorChange: (value: string) => void;
    onScale: () => void;
    onReset: () => void;
    onPrint: () => void;
    onOpenNode: (node: GraphNode | null) => void;
    graphPayload: { graph: import('../lib/types').GraphDocument | null } | null;
  } = $props();

  function nodeForIdLocal(id: string) {
    if (!graphPayload?.graph) return null;
    return graphPayload.graph.nodes.find((n) => n.id === id) ?? null;
  }
</script>

{#if activeNode?.recipe}
  <section class="recipe-pane" aria-labelledby="recipe-heading">
    <div class="problems-heading">
      <div>
        <h3 id="recipe-heading">Recipe</h3>
        <p>Read-only Boris <code>recipe</code> facet. Source remains the <code>.cook</code> file. Scale recipe asks the compiler; it does not write quantities back.</p>
      </div>
      <button type="button" onclick={onPrint}>Print this recipe</button>
    </div>
    <div class="recipe-scale">
      <label>
        Scale factor
        <input type="text" name="scale-factor" value={scaleFactor} oninput={(e) => onFactorChange((e.currentTarget as HTMLInputElement).value)} autocomplete="off" />
      </label>
      <button type="button" disabled={commandRunning} onclick={onScale}>Scale recipe</button>
      <button type="button" disabled={visibleScaleView === null} onclick={onReset}>Reset scale</button>
    </div>
    <h4>Ingredients</h4>
    <table class="recipe-table">
      <thead><tr><th>Name</th><th>Quantity</th><th>Preparation</th><th>Recipe reference</th></tr></thead>
      <tbody>
        {#each activeNode.recipe.ingredients as ingredient, ingredientIndex (`${ingredient.name}-${ingredientIndex}`)}
          <tr>
            <td>{ingredient.name}</td>
            <td>{displayQuantity(ingredient.quantity, visibleScaleView?.ingredients[ingredientIndex]?.quantity, false)}</td>
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
        {#each activeNode.recipe.cookware as item, itemIndex (`cookware-${item.name}-${itemIndex}`)}
          <tr><td>{item.name}</td><td>{displayQuantity(item.quantity, visibleScaleView?.cookware[itemIndex]?.quantity, false)}</td></tr>
        {/each}
      </tbody>
    </table>
    <h4>Timers</h4>
    <table class="recipe-table">
      <thead><tr><th>Name</th><th>Quantity</th></tr></thead>
      <tbody>
        {#each activeNode.recipe.timers as timer, timerIndex (`timer-${timer.name}-${timerIndex}`)}
          <tr><td>{timer.name || 'timer'}</td><td>{displayQuantity(timer.quantity, visibleScaleView?.timers[timerIndex]?.quantity, true)}</td></tr>
        {/each}
      </tbody>
    </table>
  </section>
{/if}
