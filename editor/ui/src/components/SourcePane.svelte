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
  import GraphPane from './GraphPane.svelte';
  import RecipePane from './RecipePane.svelte';
  import ThemePane from './ThemePane.svelte';
  import PublicationPane from './PublicationPane.svelte';

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
    <GraphPane
      {activeNode}
      {parentNode}
      {graphChildren}
      {graphSiblings}
      {graphOutgoing}
      {graphBacklinks}
      {graphRelations}
      {bufferWikiLinks}
      {graphStatus}
      {graphPayload}
      {commandRunning}
      onOpenPath={onOpenGraphPath}
      onOpenNode={onOpenGraphNode}
      onImpact={onImpact}
    />
    <RecipePane
      {activeNode}
      {scaleFactor}
      {visibleScaleView}
      {commandRunning}
      onFactorChange={onScaleFactorChange}
      onScale={onScale}
      onReset={onReset}
      onPrint={onPrint}
      onOpenNode={onOpenGraphNode}
      {graphPayload}
    />
    <ThemePane
      {themeLayoutOpen}
      {closedLayoutSlots}
      {layoutSlotsInBuffer}
      {layoutSlotsMissing}
      {themeAssets}
      {layoutSelections}
      onOpenFile={onOpenFile}
      onNavigate={onNavigate}
    />
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
  <PublicationPane
    {publicationPayload}
    {publicationStatus}
    {selectedProfile}
    {lastPublicationPlan}
    {commandRunning}
    onSelectProfile={onSelectProfile}
    onRunPlan={onRunPlan}
  />
</section>
