<script lang="ts">
  // A Boris stdout/stderr report (#991). Short reports stay inline; a large
  // one starts collapsed behind an explicit "Show …" summary so a wall of
  // text cannot bury the command that produced it. The report bytes are
  // rendered verbatim either way.
  const COLLAPSE_LINES = 24;

  let {
    summary,
    report
  }: {
    summary: string;
    report: string;
  } = $props();

  const lines = $derived(report === '' ? 0 : report.split('\n').length);
  const large = $derived(lines > COLLAPSE_LINES);
</script>

{#if large}
  <details class="report-details">
    <summary>Show {summary} ({lines} lines)</summary>
    <pre class="proof-report">{report}</pre>
  </details>
{:else}
  <pre class="proof-report">{report}</pre>
{/if}
