<script lang="ts">
  import type { PublicationPayload, PublicationPlan } from '../lib/types';

  let {
    publicationPayload,
    publicationStatus,
    selectedProfile,
    lastPublicationPlan,
    commandRunning,
    onSelectProfile,
    onRunPlan
  }: {
    publicationPayload: PublicationPayload | null;
    publicationStatus: string;
    selectedProfile: string;
    lastPublicationPlan: PublicationPlan | null;
    commandRunning: boolean;
    onSelectProfile: (value: string) => void;
    onRunPlan: () => void;
  } = $props();
</script>

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
