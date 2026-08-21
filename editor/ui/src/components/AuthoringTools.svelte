<script lang="ts">
  import type { AuthoringPayload, CompletionKind, Suggestion } from '../lib/types';
  import { schemaHint } from '../lib/utils';

  let {
    authoring,
    authoringStatus,
    completionKind,
    completionQuery,
    suggestions,
    selectedSuggestion,
    completionOpen,
    readOnly,
    onKindChange,
    onQueryChange,
    onSelect,
    onInsert,
    onRefresh,
    onCompletionKeydown,
    onCompletionOpen
  }: {
    authoring: AuthoringPayload | null;
    authoringStatus: string;
    completionKind: CompletionKind;
    completionQuery: string;
    suggestions: Suggestion[];
    selectedSuggestion: number;
    completionOpen: boolean;
    readOnly: boolean;
    onKindChange: (kind: CompletionKind) => void;
    onQueryChange: (query: string) => void;
    onSelect: (index: number) => void;
    onInsert: (suggestion: Suggestion | undefined) => void;
    onRefresh: () => void;
    onCompletionKeydown: (event: KeyboardEvent) => void;
    onCompletionOpen: (open: boolean) => void;
  } = $props();
</script>

<aside class="authoring-tools" aria-labelledby="authoring-heading">
  <div class="authoring-heading">
    <div>
      <h3 id="authoring-heading">Boris authoring hints</h3>
      <p>{authoringStatus}</p>
    </div>
    <button type="button" onclick={onRefresh}>Refresh Boris suggestions</button>
  </div>
  <div class="completion-controls">
    <div>
      <label for="completion-kind">Completion category</label>
      <select
        id="completion-kind"
        value={completionKind}
        onchange={(e) => onKindChange((e.currentTarget as HTMLSelectElement).value as CompletionKind)}
      >
        <option value="frontmatter_key">Frontmatter key</option>
        <option value="status">Status value</option>
        <option value="entity">Entity id</option>
        <option value="wiki_link">Wiki link</option>
        <option value="parent">Parent target</option>
        <option value="relation_kind">Relation kind</option>
        <option value="relation_target">Relation target</option>
        <option value="layout_slot">Layout slot</option>
      </select>
    </div>
    <div class="combobox-wrap">
      <label for="completion-query">Filter {completionKind.replaceAll('_', ' ')}</label>
      <input
        id="completion-query"
        role="combobox"
        aria-autocomplete="list"
        aria-expanded={completionOpen && suggestions.length > 0}
        aria-controls="completion-options"
        aria-activedescendant={completionOpen && suggestions.length ? `completion-option-${selectedSuggestion}` : undefined}
        value={completionQuery}
        onfocus={() => onCompletionOpen(true)}
        oninput={(e) => {
          onQueryChange((e.currentTarget as HTMLInputElement).value);
          onCompletionOpen(true);
        }}
        onkeydown={onCompletionKeydown}
      />
      <p class="key-hint"><kbd>↑</kbd><kbd>↓</kbd> navigate · <kbd>Enter</kbd> insert · <kbd>Esc</kbd> close</p>
    </div>
    <button type="button" disabled={!suggestions.length || readOnly} onclick={() => onInsert(suggestions[selectedSuggestion])}>Insert selected completion</button>
  </div>
  {#if completionOpen && suggestions.length > 0}
    <ul id="completion-options" role="listbox" aria-label="Boris completion suggestions">
      {#each suggestions as suggestion, suggestionIndex (`${completionKind}-${suggestion.value}`)}
        <li
          id="completion-option-{suggestionIndex}"
          role="option"
          tabindex="-1"
          aria-selected={suggestionIndex === selectedSuggestion}
          class:selected={suggestionIndex === selectedSuggestion}
          onclick={() => onSelect(suggestionIndex)}
          onkeydown={(event) => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              onInsert(suggestion);
            }
          }}
        >
          <strong>{suggestion.value}</strong><span>{suggestion.detail}</span>
        </li>
      {/each}
    </ul>
  {/if}
  {#if authoring}
    <details>
      <summary>Frontmatter field bounds from Boris schema</summary>
      <dl>
        {#each Object.entries(authoring.frontmatter_schema.properties) as [field, property]}
          <div><dt>{field}</dt><dd>{schemaHint(property)}</dd></div>
        {/each}
      </dl>
      <p>The schema is a looser pre-check for multibyte lengths and dates. The Boris parser remains authoritative.</p>
    </details>
  {/if}
</aside>
