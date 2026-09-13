<script lang="ts">
  import type { CompletionKind } from '../lib/types';
  import { schemaHint } from '../lib/utils';
  import { authoring, suggestions, changeCompletionKind, refreshAuthoring } from '../lib/state/authoring.svelte';
  import { buffer, insertSuggestion } from '../lib/state/buffer.svelte';

  // The completion combobox owns its keyboard behavior: Esc closes the list,
  // the arrows move the active suggestion, Enter inserts it. Focus and input
  // always reopen the list after an Esc close.
  function completionKeydown(event: KeyboardEvent) {
    if (event.key === 'Escape') {
      authoring.completionOpen = false;
      return;
    }
    if (!suggestions().length || !authoring.completionOpen) return;
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      authoring.selectedSuggestion = (authoring.selectedSuggestion + 1) % suggestions().length;
    }
    if (event.key === 'ArrowUp') {
      event.preventDefault();
      authoring.selectedSuggestion = (authoring.selectedSuggestion + suggestions().length - 1) % suggestions().length;
    }
    if (event.key === 'Enter') {
      event.preventDefault();
      void insertSuggestion(suggestions()[authoring.selectedSuggestion]);
    }
  }
</script>

<aside class="authoring-tools" aria-labelledby="authoring-heading">
  <div class="pane-heading">
    <div>
      <h3 id="authoring-heading">Boris authoring hints</h3>
      <p>{authoring.status}</p>
    </div>
    <button type="button" onclick={refreshAuthoring}>Refresh Boris suggestions</button>
  </div>
  <div class="completion-controls">
    <div>
      <label for="completion-kind">Completion category</label>
      <select
        id="completion-kind"
        value={authoring.completionKind}
        onchange={(e) => { authoring.completionKind = (e.currentTarget as HTMLSelectElement).value as CompletionKind; void changeCompletionKind(); }}
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
      <label for="completion-query">Filter {authoring.completionKind.replaceAll('_', ' ')}</label>
      <input
        id="completion-query"
        role="combobox"
        aria-autocomplete="list"
        aria-expanded={authoring.completionOpen && suggestions().length > 0}
        aria-controls="completion-options"
        aria-activedescendant={authoring.completionOpen && suggestions().length ? `completion-option-${authoring.selectedSuggestion}` : undefined}
        value={authoring.completionQuery}
        onfocus={() => (authoring.completionOpen = true)}
        oninput={(e) => {
          authoring.completionQuery = (e.currentTarget as HTMLInputElement).value;
          authoring.completionOpen = true;
        }}
        onkeydown={completionKeydown}
      />
      <p class="key-hint"><kbd>↑</kbd><kbd>↓</kbd> navigate · <kbd>Enter</kbd> insert · <kbd>Esc</kbd> close</p>
    </div>
    <button type="button" disabled={!suggestions().length || buffer.readOnly} onclick={() => insertSuggestion(suggestions()[authoring.selectedSuggestion])}>Insert selected completion</button>
  </div>
  {#if authoring.completionOpen && suggestions().length > 0}
    <ul id="completion-options" role="listbox" aria-label="Boris completion suggestions">
      {#each suggestions() as suggestion, suggestionIndex (`${authoring.completionKind}-${suggestion.value}`)}
        <li
          id="completion-option-{suggestionIndex}"
          role="option"
          tabindex="-1"
          aria-selected={suggestionIndex === authoring.selectedSuggestion}
          aria-label="{suggestion.value}; {suggestion.detail}"
          class:selected={suggestionIndex === authoring.selectedSuggestion}
          onclick={() => (authoring.selectedSuggestion = suggestionIndex)}
          onkeydown={(event) => {
            if (event.key === 'Enter' || event.key === ' ') {
              event.preventDefault();
              void insertSuggestion(suggestion);
            }
          }}
        >
          <strong>{suggestion.value}</strong><span>{suggestion.detail}</span>
        </li>
      {/each}
    </ul>
  {/if}
  {#if authoring.payload}
    <details>
      <summary>Frontmatter field bounds from Boris schema</summary>
      <dl>
        {#each Object.entries(authoring.payload.frontmatter_schema.properties) as [field, property]}
          <div><dt>{field}</dt><dd>{schemaHint(property)}</dd></div>
        {/each}
      </dl>
      <p>The schema is a looser pre-check for multibyte lengths and dates. The Boris parser remains authoritative.</p>
    </details>
  {/if}
</aside>
