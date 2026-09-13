<script lang="ts">
  import type { Snippet } from 'svelte';

  // One action row of the editor's shared hierarchy language (#991): a
  // labelled group whose tone carries primary vs secondary weight. Buttons
  // keep their own accessible names; the group label is only a landmark for
  // assistive tech and pointer grouping.
  let {
    label,
    tone = 'plain',
    children
  }: {
    label: string;
    tone?: 'plain' | 'primary' | 'secondary';
    children: Snippet;
  } = $props();
</script>

<div class="action-group action-group-{tone}" role="group" aria-label={label}>
  {@render children()}
</div>
