<script lang="ts">
  import type {
    AuthoringPayload,
    CompletionKind,
    Suggestion,
    Problem,
    GraphDocument,
    GraphNode,
    GraphLink,
    FileEntry,
    PublicationPayload,
    PublicationPlan,
    RecipeScaleView
  } from '../lib/types';
  import { displayQuantity, quantityLabel, problemLocationLabel } from '../lib/utils';
  import AuthoringTools from './AuthoringTools.svelte';

  let {
    activePath,
    content,
    readOnly,
    undoStack,
    redoStack,
    dirty,
    saveInFlight,
    authoring,
    authoringStatus,
    completionKind,
    completionQuery,
    suggestions,
    selectedSuggestion,
    completionOpen,
    activeProblems,
    staleProblems,
    editorStatus,
    graphPayload,
    graphStatus,
    activeNode,
    parentNode,
    graphChildren,
    graphSiblings,
    graphOutgoing,
    graphBacklinks,
    graphRelations,
    bufferWikiLinks,
    commandRunning,
    scaleFactor,
    scaleView,
    visibleScaleView,
    themeLayoutOpen,
    closedLayoutSlots,
    layoutSlotsInBuffer,
    layoutSlotsMissing,
    themeAssets,
    layoutSelections,
    publicationPayload,
    publicationStatus,
    selectedProfile,
    lastPublicationPlan,
    onInput,
    onSave,
    onUndo,
    onRedo,
    onSelect,
    onInsert,
    onKindChange,
    onQueryChange,
    onRefresh,
    onCompletionKeydown,
    onCompletionOpen,
    onTrackCursor,
    onNavigate,
    onOpenGraphPath,
    onOpenGraphNode,
    onImpact,
    onScaleFactorChange,
    onScale,
    onReset,
    onPrint,
    onOpenFile,
    onSelectProfile,
    onRunPlan
  }: {
    activePath: string;
    content: string;
    readOnly: boolean;
    undoStack: string[];
    redoStack: string[];
    dirty: boolean;
    saveInFlight: boolean;
    authoring: AuthoringPayload | null;
    authoringStatus: string;
    completionKind: CompletionKind;
    completionQuery: string;
    suggestions: Suggestion[];
    selectedSuggestion: number;
    completionOpen: boolean;
    activeProblems: Problem[];
    staleProblems: Set<Problem>;
    editorStatus: string;
    graphPayload: { graph: GraphDocument | null } | null;
    graphStatus: string;
    activeNode: GraphNode | null;
    parentNode: GraphNode | null;
    graphChildren: GraphLink[];
    graphSiblings: GraphLink[];
    graphOutgoing: GraphLink[];
    graphBacklinks: GraphLink[];
    graphRelations: Array<{ kind: string; target: string }>;
    bufferWikiLinks: Array<{ id: string; node: GraphNode | null }>;
    commandRunning: boolean;
    scaleFactor: string;
    scaleView: RecipeScaleView | null;
    visibleScaleView: RecipeScaleView | null;
    themeLayoutOpen: boolean;
    closedLayoutSlots: string[];
    layoutSlotsInBuffer: string[];
    layoutSlotsMissing: string[];
    themeAssets: FileEntry[];
    layoutSelections: Problem[];
    publicationPayload: PublicationPayload | null;
    publicationStatus: string;
    selectedProfile: string;
    lastPublicationPlan: PublicationPlan | null;
    onInput: (event: Event) => void;
    onSave: () => void;
    onUndo: () => void;
    onRedo: () => void;
    onSelect: (index: number) => void;
    onInsert: (suggestion: Suggestion | undefined) => void;
    onKindChange: (kind: CompletionKind) => void;
    onQueryChange: (query: string) => void;
    onRefresh: () => void;
    onCompletionKeydown: (event: KeyboardEvent) => void;
    onCompletionOpen: (open: boolean) => void;
    onTrackCursor: () => void;
    onNavigate: (problem: Problem) => void;
    onOpenGraphPath: (path: string) => void;
    onOpenGraphNode: (node: GraphNode | null) => void;
    onImpact: () => void;
    onScaleFactorChange: (value: string) => void;
    onScale: () => void;
    onReset: () => void;
    onPrint: () => void;
    onOpenFile: (path: string) => void;
    onSelectProfile: (value: string) => void;
    onRunPlan: () => void;
  } = $props();

  function nodeForIdLocal(id: string): GraphNode | null {
    if (!graphPayload?.graph) return null;
    return graphPayload.graph.nodes.find((n) => n.id === id) ?? null;
  }
</script>

<section id="source" class="source-pane" tabindex="-1" aria-labelledby="source-heading">
  <div class="source-heading">
    <div>
      <h2 id="source-heading">Source</h2>
      <p class="path">{activePath || 'No file selected'}</p>
    </div>
    <div class="source-actions" aria-label="Editing actions">
      <button type="button" disabled={undoStack.length === 0 || readOnly} onclick={onUndo}>Undo</button>
      <button type="button" disabled={redoStack.length === 0 || readOnly} onclick={onRedo}>Redo</button>
      <button type="button" class="primary" disabled={!dirty || readOnly || saveInFlight} onclick={onSave}>Save file</button>
    </div>
  </div>
  {#if activePath}
    <label for="source-editor">Source for {activePath}</label>
    <textarea
      id="source-editor"
      value={content}
      readonly={readOnly}
      spellcheck="false"
      oninput={onInput}
      onselect={onTrackCursor}
      onclick={onTrackCursor}
      onkeyup={onTrackCursor}
    ></textarea>
    <AuthoringTools
      {authoring}
      {authoringStatus}
      {completionKind}
      {completionQuery}
      {suggestions}
      {selectedSuggestion}
      {completionOpen}
      {readOnly}
      onKindChange={onKindChange}
      onQueryChange={onQueryChange}
      onSelect={onSelect}
      onInsert={onInsert}
      onRefresh={onRefresh}
      onCompletionKeydown={onCompletionKeydown}
      onCompletionOpen={onCompletionOpen}
    />
    <section id="graph" class="graph-pane" aria-labelledby="graph-heading">
      <div class="problems-heading">
        <div>
          <h3 id="graph-heading">Graph</h3>
          <p>Read-only view of Boris <code>graph.json</code> and <code>completion.json</code>.</p>
        </div>
      </div>
      <p role="status" aria-label="Graph status" aria-live="polite">{graphStatus}</p>
      {#if activeNode}
        <p class="graph-current">{activeNode.id}{activeNode.title ? ` · ${activeNode.title}` : ''} · {activeNode.role}{activeNode.status ? ` · ${activeNode.status}` : ''}</p>
        <div class="graph-actions" aria-label="Graph navigation">
          {#if parentNode}
            <button type="button" onclick={() => onOpenGraphNode(parentNode)}>Go to parent {parentNode.id}</button>
          {/if}
          <button type="button" disabled={commandRunning} onclick={onImpact}>Run impact on {activeNode.id}</button>
        </div>
        {#if graphChildren.length > 0}
          <h4>Children</h4>
          <ul class="graph-links">
            {#each graphChildren as link (link.path)}
              <li><button type="button" onclick={() => onOpenGraphPath(link.path)}>Go to child {link.label}</button></li>
            {/each}
          </ul>
        {/if}
        {#if graphSiblings.length > 0}
          <h4>Siblings</h4>
          <ul class="graph-links">
            {#each graphSiblings as link (link.path)}
              <li><button type="button" onclick={() => onOpenGraphPath(link.path)}>Go to sibling {link.label}</button></li>
            {/each}
          </ul>
        {/if}
        {#if graphOutgoing.length > 0}
          <h4>Outgoing references and includes</h4>
          <ul class="graph-links">
            {#each graphOutgoing as link (`${link.kind}:${link.path}`)}
              <li><button type="button" onclick={() => onOpenGraphPath(link.path)}>Go to {link.label}</button></li>
            {/each}
          </ul>
        {/if}
        {#if graphBacklinks.length > 0}
          <h4>Backlinks</h4>
          <ul class="graph-links">
            {#each graphBacklinks as link (`back:${link.kind}:${link.path}`)}
              <li><button type="button" onclick={() => onOpenGraphPath(link.path)}>Go to backlink {link.label}</button></li>
            {/each}
          </ul>
        {/if}
        {#if graphRelations.length > 0}
          <h4>Relations from completion.json</h4>
          <ul class="graph-links">
            {#each graphRelations as relation (`${relation.kind}:${relation.target}`)}
              <li>
                {#if nodeForIdLocal(relation.target)}
                  <button type="button" onclick={() => onOpenGraphNode(nodeForIdLocal(relation.target))}>
                    Go to {relation.kind} {relation.target}
                  </button>
                {:else}
                  <span>{relation.kind} {relation.target}</span>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
        {#if bufferWikiLinks.length > 0}
          <h4>Wiki links in this buffer</h4>
          <ul class="graph-links">
            {#each bufferWikiLinks as link (link.id)}
              <li>
                {#if link.node}
                  <button type="button" onclick={() => onOpenGraphNode(link.node)}>Go to wiki link {link.id}</button>
                {:else}
                  <span>Unresolved wiki link {link.id}</span>
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
      {:else if graphPayload?.graph}
        <p>This file is not a page in the Boris graph.</p>
      {/if}
    </section>
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
            <input type="text" name="scale-factor" value={scaleFactor} oninput={(e) => onScaleFactorChange((e.currentTarget as HTMLInputElement).value)} autocomplete="off" />
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
                    <button type="button" onclick={() => onOpenGraphNode(nodeForIdLocal(ingredient.recipeRef!))}>
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
    {#if themeLayoutOpen}
      <section class="theme-pane" aria-labelledby="theme-heading">
        <div class="problems-heading">
          <div>
            <h3 id="theme-heading">Theme layout</h3>
            <p>Closed slots come from Boris <code>completion.json</code>. The buffer scan is presentation only.</p>
          </div>
        </div>
        <p class="fallback-notice">Layout winners appear as <code>ILAYOUTSELECTED</code> after Build HTML or Validate. Fallback winners appear when the target has layout rules.</p>
        {#if closedLayoutSlots.length === 0}
          <p>Build diagnostics to load the closed layout-slot vocabulary.</p>
        {:else}
          <h4>Slots in this layout</h4>
          <ul class="graph-links">
            {#each layoutSlotsInBuffer as slot (slot)}
              <li>Present: <code>{'{{' + slot + '}}'}</code></li>
            {/each}
          </ul>
          {#if layoutSlotsMissing.length > 0}
            <h4>Closed slots not in this file</h4>
            <ul class="graph-links">
              {#each layoutSlotsMissing as slot (slot)}
                <li>Absent: <code>{'{{' + slot + '}}'}</code></li>
              {/each}
            </ul>
          {/if}
        {/if}
        {#if themeAssets.length > 0}
          <h4>Theme assets</h4>
          <ul class="graph-links">
            {#each themeAssets as asset (asset.path)}
              <li><button type="button" onclick={() => onOpenFile(asset.path)}>Open {asset.path}</button></li>
            {/each}
          </ul>
        {/if}
        {#if layoutSelections.length > 0}
          <h4>Layout selection from the last HTML report</h4>
          <ul class="graph-links">
            {#each layoutSelections as problem}
              <li>
                {#if problem.source_path}
                  <button type="button" onclick={() => onNavigate(problem)}>
                    {problemLocationLabel(problem)}: {problem.message}
                  </button>
                {:else}
                  {problem.message}
                {/if}
              </li>
            {/each}
          </ul>
        {/if}
      </section>
    {/if}
    <p class:warning={dirty || readOnly} class="buffer-state">
      {readOnly ? 'Read-only file' : dirty ? 'Unsaved changes' : 'Saved on disk'}
    </p>
    {#if activeProblems.length > 0}
      <aside class="inline-problems" aria-label="Problems in {activePath}">
        <h3>Problems in this file</h3>
        <ul>
          {#each activeProblems as problem}
            <li>
              <button type="button" onclick={() => onNavigate(problem)}>
                Go to {problemLocationLabel(problem)}: {problem.code ?? 'Unstructured Boris output'}
              </button>
              {#if staleProblems.has(problem)}
                <p class="warning-text">Possibly stale — the open buffer changed this region since the report.</p>
              {/if}
            </li>
          {/each}
        </ul>
      </aside>
    {/if}
  {:else}
    <p>Choose a file from Project files. Generated output and editor state are intentionally excluded.</p>
    <section id="graph" class="graph-pane" aria-labelledby="graph-heading-empty">
      <h3 id="graph-heading-empty">Graph</h3>
      <p role="status" aria-label="Graph status" aria-live="polite">{graphStatus}</p>
    </section>
  {/if}
  <p role="status" aria-label="Editing status" aria-live="polite">{editorStatus}</p>
  <section id="publication" class="publication-pane" aria-labelledby="publication-heading">
    <div class="problems-heading">
      <div>
        <h2 id="publication-heading">Publication</h2>
        <p>The editor runs <code>boris plan --profile</code> and shows the normalized declaration. It does not deploy or store secrets.</p>
      </div>
    </div>
    <p role="status" aria-label="Publication status" aria-live="polite">{publicationStatus}</p>
    {#if (publicationPayload?.profiles.length ?? 0) > 0}
      <label for="publication-profile">Publication profile</label>
      <div class="impact-command">
        <div>
          <select id="publication-profile" value={selectedProfile} disabled={commandRunning} onchange={(e) => onSelectProfile((e.currentTarget as HTMLSelectElement).value)}>
            {#each publicationPayload?.profiles ?? [] as profile (profile.path)}
              <option value={profile.path}>{profile.path}</option>
            {/each}
          </select>
          <button type="button" disabled={commandRunning || !selectedProfile} onclick={onRunPlan}>Run publication plan</button>
        </div>
      </div>
    {:else}
      <p>Add a <code>boris-publication-profile</code> file such as <code>boris.json</code> at the project root. The compiler does not invent profiles.</p>
    {/if}
    {#if lastPublicationPlan}
      {@const plan = lastPublicationPlan}
      <h3>Normalized plan</h3>
      <p>This JSON is a static declaration. Success here means only that Boris validated the profile. It is not proof, evidence, or a deployed site.</p>
      <dl>
        <div><dt>Input</dt><dd>{plan.input} · {plan.input_format}</dd></div>
        {#if plan.site?.title}<div><dt>Site</dt><dd>{plan.site.title}{plan.site.url ? ` · ${plan.site.url}` : ''}</dd></div>{/if}
        {#if plan.publication}
          <div><dt>Declared target</dt><dd>{plan.publication.target ?? 'none'}</dd></div>
          {#if plan.publication.base_url}
            <div><dt>Public location</dt><dd>{plan.publication.base_url} ({plan.publication.origin ?? ''}{plan.publication.base_path ?? ''}{plan.publication.site_kind ? ` · ${plan.publication.site_kind}` : ''})</dd></div>
          {/if}
        {:else}
          <div><dt>Declared target</dt><dd>None. This is a local HTML/edition declaration, not a hosted platform identity.</dd></div>
        {/if}
      </dl>
      {#if plan.targets.length > 0}
        <h4>Targets</h4>
        <ul class="graph-links">
          {#each plan.targets as target (target.name)}
            <li>{target.name} → {target.output}{target.public ? ' · public' : ''}{target.theme ? ` · ${target.theme}` : ''}{target.layout ? ` · ${target.layout}` : ''}</li>
          {/each}
        </ul>
      {/if}
        {#if plan.publication?.target === 'github-pages'}
          <p class="fallback-notice">GitHub Pages is the verified target. Deploy stays in the official Actions workflow: resolve location, fail closed on URL disagreement, upload only inventory-verified files. This editor does not run that workflow.</p>
        {:else if plan.publication?.target === 'standard-site'}
          <p class="fallback-notice">Standard.site is a verified first-tester target. Plan and publish stay on the Boris CLI. The editor does not log in or publish.</p>
        {:else if plan.publication?.target}
          <p class="fallback-notice">{plan.publication.target} is declared in the plan. The editor does not add a platform adapter or treat this as a verified deploy.</p>
        {/if}
    {/if}
    {#if publicationPayload?.proof}
      {@const proof = publicationPayload.proof}
      <h3>Local evidence</h3>
      <p>The Proof Pack at <code>{proof.path}</code> is target-local presentation of committed artifacts, checks, and claims. It does not verify a deployed site.</p>
      <dl>
        <div><dt>Target</dt><dd>{proof.target}</dd></div>
        <div><dt>Presentation status</dt><dd>{proof.overall_presentation_status}</dd></div>
        <div><dt>Counts</dt><dd>{proof.artifacts_total} artifacts · {proof.checks_total} checks · {proof.findings_total} findings · {proof.claims_total} claims</dd></div>
      </dl>
        <p>Limitation <code>no-deployment-verification</code> is part of every Proof Pack. Local build verification and deployed-site verification are different facts.</p>
    {:else}
      <p>No local Proof Pack at <code>dist/_boris/proof/proof-pack.json</code> yet. Build HTML to produce evidence; that still is not a deploy.</p>
    {/if}
  </section>
</section>
