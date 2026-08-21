<script lang="ts">
  import type { CommandResult, Problem, ProblemGroup, ValidateState } from '../lib/types';
  import {
    failureLabel,
    problemLocationLabel,
    packetCopyLabel,
    packetCopyKey,
    validationStatusLabel,
    validationCycleLabel
  } from '../lib/utils';

  let {
    problemsNotice,
    problemGroups,
    staleProblems,
    commandResult,
    validateDaemon,
    validateState,
    commandStatus,
    dirty,
    commandRunning,
    impactId,
    copiedPacketKey,
    onRunCommand,
    onImpactInput,
    onNavigate,
    onCopyPacket
  }: {
    problemsNotice: { text: string; clean: boolean };
    problemGroups: ProblemGroup[];
    staleProblems: Set<Problem>;
    commandResult: CommandResult | null;
    validateDaemon: boolean;
    validateState: ValidateState | null;
    commandStatus: string;
    dirty: boolean;
    commandRunning: boolean;
    impactId: string;
    copiedPacketKey: string;
    onRunCommand: (mode: 'validate' | 'ir_build' | 'html_build' | 'check' | 'impact') => void;
    onImpactInput: (value: string) => void;
    onNavigate: (problem: Problem) => void;
    onCopyPacket: (problem: Problem) => void;
  } = $props();
</script>

<section id="problems" class="problems-pane" aria-labelledby="problems-heading">
  <div class="problems-heading">
    <div>
      <h2 id="problems-heading">Problems</h2>
      <p>Every result below comes from the Boris CLI or one of its published artifacts.</p>
    </div>
    {#if commandResult}
      <p class:failure={commandResult.failure_class !== 'success'} class="command-result">
        {failureLabel(commandResult.failure_class, commandResult.exit_code)}
      </p>
    {/if}
  </div>
  {#if validateDaemon}
    <div class="validation-state-line">
      <p class="validation-state" role="status" aria-label="Validation state" aria-live="polite">{validationStatusLabel(validateState)}</p>
      <span class="validation-meta" aria-label="Validation cycle and report age">{validationCycleLabel(validateState)}</span>
    </div>
  {/if}
  {#if problemsNotice.text}
    <p class="problems-notice" role="status" aria-label="Problems notice" aria-live="polite">{problemsNotice.text}</p>
  {/if}
  {#if dirty && ((commandResult?.problems.length ?? 0) > 0 || problemsNotice.clean)}
    <p class="warning-text">Problems reflect saved files; the open buffer has unsaved changes.</p>
  {/if}
  <div class="command-bar" aria-label="Boris commands">
    <button type="button" disabled={commandRunning} onclick={() => onRunCommand('validate')}>Validate project</button>
    <button type="button" disabled={commandRunning} onclick={() => onRunCommand('ir_build')}>Build diagnostics</button>
    <button type="button" disabled={commandRunning} onclick={() => onRunCommand('html_build')}>Build HTML</button>
    <button type="button" disabled={commandRunning} onclick={() => onRunCommand('check')}>Check graph</button>
  </div>
  <div class="impact-command">
    <label for="impact-id">Impact entity or source endpoint</label>
    <div>
      <input id="impact-id" value={impactId} disabled={commandRunning} oninput={(e) => onImpactInput((e.currentTarget as HTMLInputElement).value)} />
      <button type="button" disabled={commandRunning} onclick={() => onRunCommand('impact')}>Run impact</button>
    </div>
  </div>
  {#if dirty}
    <p class="warning-text">Boris commands read repository files from disk. Choose Save &amp; run or Discard &amp; run to resolve the unsaved buffer.</p>
  {/if}
  <p role="status" aria-label="Boris command status" aria-live="polite">{commandStatus}</p>
  {#if commandResult?.used_stderr_fallback}
    <p class="fallback-notice">Machine-readable diagnostics were unavailable for this command. Boris stderr was used; reported source positions are labeled best-effort.</p>
  {/if}
  {#if commandResult && commandResult.problems.length === 0 && !problemsNotice.text}
    <p>No Boris diagnostics were reported by the last command.</p>
  {/if}
  <div class="problem-groups" aria-label="Boris diagnostic groups">
    {#each problemGroups as group, groupIndex (group.key)}
      <section class="problem-group" aria-labelledby="problem-group-{groupIndex}">
        <h3 id="problem-group-{groupIndex}">{group.label}</h3>
        <ul>
          {#each group.problems as problem}
            <li class="problem-card">
              <p>{problem.message}</p>
              {#if staleProblems.has(problem)}
                <p class="warning-text">Possibly stale — the open buffer changed this region since the report.</p>
              {/if}
              {#if problem.remediation}<p><strong>Remediation:</strong> {problem.remediation}</p>{/if}
              <p class="confidence">
                {problem.position_confidence === 'exact'
                  ? 'Exact compiler-reported source position'
                  : problem.position_confidence === 'best_effort'
                    ? (problem.source_path?.endsWith('.cook') && problem.code !== 'ECOOKLANG'
                      ? 'Position approximate: graph diagnostic on adapted Markdown, not the .cook line'
                      : 'Best-effort source position')
                    : 'No source position reported'}
              </p>
              <div class="problem-actions">
                {#if problem.source_path}
                  <button type="button" onclick={() => onNavigate(problem)}>Go to {problemLocationLabel(problem)}</button>
                {/if}
                <button type="button" aria-label={packetCopyLabel(problem)} onclick={() => onCopyPacket(problem)}>{copiedPacketKey === packetCopyKey(problem) ? 'Copied!' : packetCopyLabel(problem)}</button>
              </div>
            </li>
          {/each}
        </ul>
      </section>
    {/each}
  </div>
    {#if commandResult && commandResult.findings.length > 0}
      <section class="analysis-results" aria-labelledby="analysis-findings-heading">
        <h3 id="analysis-findings-heading">Analysis findings</h3>
        <ul>
          {#each commandResult.findings as finding}
            <li>
              <span>{finding.code} · {finding.endpoint_type} {finding.value} · count {finding.count}</span>
              {#if finding.source_path}
                <button type="button" onclick={() => onNavigate(finding as unknown as Problem)}>Go to {problemLocationLabel(finding as unknown as Problem)}</button>
              {/if}
            </li>
          {/each}
        </ul>
      </section>
    {/if}
    {#if commandResult?.mode === 'impact' && commandResult.impact.length > 0}
      <section class="analysis-results" aria-labelledby="impact-results-heading">
        <h3 id="impact-results-heading">Impact results</h3>
        <ul>
          {#each commandResult.impact as endpoint}
            <li>{endpoint.endpoint_type}: {endpoint.value}</li>
          {/each}
        </ul>
      </section>
    {/if}
</section>
