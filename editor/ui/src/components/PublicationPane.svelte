<script lang="ts">
  import { publication } from '../lib/state/publication.svelte';
  import { problems } from '../lib/state/problems.svelte';
  import { connection } from '../lib/state/connection.svelte';
  import type { Tone } from '../lib/utils';
  import ReportBlock from './ReportBlock.svelte';

  let {
    onRunPlan,
    onVerifyProof
  }: {
    onRunPlan: () => void;
    onVerifyProof: () => void;
  } = $props();

  // Claims about profiles and the Proof Pack are only made from a payload the
  // host actually sent; without one the pane says it is loading or unavailable.
  const payload = $derived(publication.payload);
  const statusTone = $derived<Tone | undefined>(
    !payload
      ? connection.phase === 'connecting' ? 'busy' : 'danger'
      : payload.proof_status === 'unsupported' ? 'warn'
        : undefined
  );
</script>

<section id="publication" class="subpane publication-pane" tabindex="-1" aria-labelledby="publication-heading">
  <div class="pane-heading">
    <div>
      <h3 id="publication-heading">Publication</h3>
      <p>The editor runs <code>boris plan --profile</code> and shows the normalized declaration. It does not deploy or store secrets.</p>
    </div>
    <button
      type="button"
      class="ghost"
      class:is-running={problems.running && problems.runningMode === 'proof_verify'}
      aria-busy={problems.running && problems.runningMode === 'proof_verify'}
      disabled={problems.running}
      onclick={onVerifyProof}>Verify proof</button>
  </div>
  <p class="pane-status" class:notice={statusTone !== undefined} data-tone={statusTone} role="status" aria-label="Publication status" aria-live="polite">{publication.status}</p>
  {#if (payload?.profiles.length ?? 0) > 0}
    <label for="publication-profile">Publication profile</label>
    <div class="field-row">
      <select id="publication-profile" value={publication.selectedProfile} disabled={problems.running} onchange={(e) => (publication.selectedProfile = (e.currentTarget as HTMLSelectElement).value)}>
        {#each payload?.profiles ?? [] as profile (profile.path)}
          <option value={profile.path}>{profile.path}</option>
        {/each}
      </select>
      <button
        type="button"
        class="primary"
        class:is-running={problems.running && problems.runningMode === 'plan'}
        aria-busy={problems.running && problems.runningMode === 'plan'}
        disabled={problems.running || !publication.selectedProfile}
        onclick={onRunPlan}>Run publication plan</button>
    </div>
  {:else if payload}
    <p class="empty-state">Add a <code>boris-publication-profile</code> file such as <code>boris.json</code> at the project root. The compiler does not invent profiles.</p>
  {/if}
  {#if publication.lastPlan}
    {@const plan = publication.lastPlan}
    <h4>Normalized plan</h4>
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
      <ul class="graph-links row-list">
        {#each plan.targets as target (target.name)}
          <li>{target.name} → {target.output}{target.public ? ' · public' : ''}{target.theme ? ` · ${target.theme}` : ''}{target.layout ? ` · ${target.layout}` : ''}</li>
        {/each}
      </ul>
    {/if}
    {#if plan.publication?.target === 'github-pages'}
      <p class="notice">GitHub Pages is the verified target. Deploy stays in the official Actions workflow: resolve location, fail closed on URL disagreement, upload only inventory-verified files. This editor does not run that workflow.</p>
    {:else if plan.publication?.target === 'standard-site'}
      <p class="notice">Standard.site is a verified first-tester target. Plan and publish stay on the Boris CLI. The editor does not log in or publish.</p>
    {:else if plan.publication?.target}
      <p class="notice">{plan.publication.target} is declared in the plan. The editor does not add a platform adapter or treat this as a verified deploy.</p>
    {/if}
  {/if}
  {#if payload?.proof}
    {@const proof = payload.proof}
    <h4>Local evidence</h4>
    <p>The Proof Pack at <code>{proof.path}</code> is target-local presentation of committed artifacts, checks, and claims. It does not verify a deployed site.</p>
    <dl>
      <div><dt>Target</dt><dd>{proof.target}</dd></div>
      <div><dt>Presentation status</dt><dd>{proof.overall_presentation_status}</dd></div>
      <div><dt>Counts</dt><dd>{proof.artifacts_total} artifacts · {proof.checks_total} checks · {proof.findings_total} findings · {proof.claims_total} claims</dd></div>
    </dl>
    <p>Limitation <code>no-deployment-verification</code> is part of every Proof Pack. Local build verification and deployed-site verification are different facts.</p>
  {:else if payload && payload.proof_status !== 'unsupported'}
    <p class="empty-state">No local Proof Pack at <code>dist/_boris/proof/proof-pack.json</code> yet. Build HTML to produce evidence; that still is not a deploy.</p>
  {/if}
  {#if publication.lastProofReport}
    <h4>Proof verify report</h4>
    <p>This is the contracted <code>boris proof verify</code> stderr. Exit class is in Problems; the editor does not invent pass or fail.</p>
    <ReportBlock summary="proof verify report" report={publication.lastProofReport} />
  {/if}
</section>
