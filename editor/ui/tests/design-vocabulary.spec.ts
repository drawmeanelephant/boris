import { expect, test, type Page } from '@playwright/test';

// Design pass (#1044). Pins the shared vocabulary where it carries meaning:
//
//   1. panes never claim "empty" before the host has answered, say they are
//      unavailable (not loading forever) when it never does, and read a
//      failed artifact refresh as an error;
//   2. tones restate host facts — a warning-severity group is not painted as
//      an error, and a startup `stale` preview is not painted as a failure;
//   3. a primary button's label and its key-hint chip stay readable in both
//      themes (the Publication plan button had inherited muted ink, and the
//      light-theme chip was white on near-white).
//
// Same mocked-host approach as the other suites: every endpoint is routed
// in-page, no Zig host is spawned.

type Json = Record<string, unknown>;

type Options = {
  theme?: 'light' | 'dark';
  healthStatus?: number;
  holdHost?: boolean;
  problems?: Json[];
  preview?: Json;
  publication?: Json;
  // Commands succeed, and every artifact request after the first one fails:
  // the shape of a build whose graph/completion refresh the host cannot adapt.
  refreshFails?: boolean;
};

function commandResult(overrides: Json = {}): Json {
  return {
    mode: 'validate', exit_code: 1, failure_class: 'content', compiler_id: 'boris/0.8.2',
    report_version: 'html-build-report-0.2.0', used_stderr_fallback: false,
    problems: [], findings: [], impact: [], ...overrides
  };
}

function problem(severity: 'error' | 'warning', code: string): Json {
  return {
    severity, code, message: `${code} message`, remediation: '', source_path: 'index.md', line: 1, column: 1,
    id: 'index', origin: 'build_report', position_confidence: 'exact', packet: `{"code":"${code}"}`
  };
}

async function installApi(page: Page, options: Options = {}) {
  const json = (body: unknown, status = 200) => ({ status, contentType: 'application/json', body: JSON.stringify(body) });
  const hold = () => new Promise<void>(() => {});
  await page.route('**/api/health', async route => {
    if (options.holdHost) await hold();
    if (options.healthStatus) return route.fulfill(json({ error: 'host_unavailable' }, options.healthStatus));
    return route.fulfill(json({ status: 'ok', editor_id: 'boris-editor/0.1.0', project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' } }));
  });
  await page.route('**/api/version', route => route.fulfill(json({ compiler_id: 'boris/0.8.2' })));
  await page.route('**/api/files', async route => {
    if (options.holdHost) await hold();
    return route.fulfill(json({ files: [{ path: 'boris.json' }, { path: 'content/index.md' }], last_open: null }));
  });
  await page.route('**/api/recovery', route => route.fulfill(json({ snapshots: [], skipped: 0 })));
  await page.route('**/api/recovery/snapshot', route => route.fulfill(json({ status: 'snapshotted' })));
  await page.route('**/api/files/probe', route => route.fulfill(json({ status: 'unchanged', fingerprint: 'a'.repeat(64), read_only: false })));
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    return route.fulfill(json({ status: 'opened', path, content: '# Home\n', fingerprint: 'a'.repeat(64), read_only: false }));
  });
  await page.route('**/api/commands/run', route => {
    const { mode } = route.request().postDataJSON() as { mode: string };
    const outcome = options.refreshFails ? { mode, exit_code: 0, failure_class: 'success' } : {};
    return route.fulfill(json(commandResult({ problems: options.problems ?? [], ...outcome })));
  });
  const requests = { authoring: 0, graph: 0 };
  await page.route('**/api/authoring', route => {
    requests.authoring += 1;
    if (options.refreshFails && requests.authoring > 1) return route.fulfill(json({ error: 'unsupported_boris_artifact' }, 502));
    return route.fulfill(json({
      frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: { id: { type: 'string' } } },
      completion: null, completion_status: 'build_required'
    }));
  });
  await page.route('**/api/graph', route => {
    requests.graph += 1;
    if (options.refreshFails && requests.graph > 1) return route.fulfill(json({ error: 'unsupported_boris_artifact' }, 502));
    return route.fulfill(json({ graph: null, graph_status: 'build_required' }));
  });
  await page.route('**/api/publication', route => route.fulfill(json(options.publication ?? { profiles: [{ path: 'boris.json' }], proof: null, proof_status: 'absent' })));
  await page.route('**/api/preview/state', route => route.fulfill(json(options.preview ?? {
    phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false,
    message: 'Preview has not been built yet.', preview_url: 'https://preview.invalid/?token=test'
  })));
  await page.route('https://preview.invalid/**', route => route.fulfill({ contentType: 'text/html', body: '<!doctype html><title>preview</title>' }));
  await page.route('**/api/watch/state', route => route.fulfill(json({ error: 'not_found' }, 404)));
  await page.route(/\/api\/watch\/events/, route => route.fulfill(json({ error: 'not_found' }, 404)));
  await page.addInitScript(theme => {
    localStorage.setItem('boris-editor-density', 'review');
    localStorage.setItem('boris-editor-theme', theme);
  }, options.theme ?? 'light');
  await page.goto('/#token=test-session-token');
}

test.describe('state honesty', () => {
  test('panes say they are loading instead of claiming nothing exists', async ({ page }) => {
    await installApi(page, { holdHost: true });
    const project = page.locator('#project');
    await expect(project.getByText('Loading project files…')).toBeVisible();
    await expect(project.getByText('No author-owned project files found.')).toHaveCount(0);
    await expect(page.locator('#problems').getByText('Connecting to the local host…')).toBeVisible();
    await expect(page.locator('#problems').getByText(/No validation report yet/)).toHaveCount(0);
    // No profile or Proof Pack claim is made from a payload that has not arrived.
    const publication = page.locator('#publication');
    await expect(publication.getByRole('status', { name: 'Publication status' })).toHaveText('Loading publication profiles…');
    await expect(publication.getByText(/Add a/)).toHaveCount(0);
    await expect(publication.getByText(/No local Proof Pack/)).toHaveCount(0);
  });

  test('a host that never connects reads as unavailable, not as loading forever', async ({ page }) => {
    await installApi(page, { healthStatus: 503 });
    await expect(page.locator('.connection-chip')).toHaveAttribute('data-tone', 'danger');
    await expect(page.locator('#project').getByText(/Project files could not be loaded/)).toBeVisible();
    await expect(page.locator('#problems').getByText(/Diagnostics are unavailable until the editor host connects/)).toBeVisible();
    await expect(page.getByRole('status', { name: 'Graph status' })).toHaveText('Boris graph is unavailable.');
    await expect(page.getByRole('status', { name: 'Graph status' })).toHaveAttribute('data-tone', 'danger');
    const publication = page.locator('#publication');
    await expect(publication.getByRole('status', { name: 'Publication status' })).toHaveText('Publication profiles are unavailable.');
    await expect(publication.getByText(/No local Proof Pack/)).toHaveCount(0);
  });

  test('a connected empty project still names its real empty states', async ({ page }) => {
    await installApi(page, { publication: { profiles: [], proof: null, proof_status: 'absent' } });
    await expect(page.locator('.connection-chip')).toHaveAttribute('data-tone', 'ok');
    const publication = page.locator('#publication');
    await expect(publication.locator('.empty-state', { hasText: 'boris-publication-profile' })).toBeVisible();
    await expect(publication.locator('.empty-state', { hasText: 'No local Proof Pack' })).toBeVisible();
  });

  test('a failed artifact refresh after a build reads as an error, not a quiet sentence', async ({ page }) => {
    await installApi(page, { refreshFails: true });
    await page.getByRole('button', { name: 'Build diagnostics', exact: true }).click();
    const graphStatus = page.getByRole('status', { name: 'Graph status' });
    await expect(graphStatus).toHaveText('The Boris build succeeded, but graph.json could not be adapted.');
    await expect(graphStatus).toHaveAttribute('data-tone', 'danger');
    await expect(page.getByText('The Boris build succeeded, but completion.json could not be adapted.'))
      .toHaveAttribute('data-tone', 'danger');
  });

  test('an unsupported Proof Pack is not also reported as missing', async ({ page }) => {
    await installApi(page, { publication: { profiles: [{ path: 'boris.json' }], proof: null, proof_status: 'unsupported' } });
    const status = page.locator('#publication').getByRole('status', { name: 'Publication status' });
    await expect(status).toContainText('stale or unsupported');
    await expect(status).toHaveAttribute('data-tone', 'warn');
    await expect(page.locator('#publication').getByText(/No local Proof Pack/)).toHaveCount(0);
  });
});

test.describe('tones restate host facts', () => {
  test('problem groups carry their own severity', async ({ page }) => {
    await installApi(page, { problems: [problem('error', 'EFRONTMATTER'), problem('warning', 'WORPHAN')] });
    await page.getByRole('button', { name: 'Validate project', exact: true }).click();
    await expect(page.locator('.problem-group', { hasText: 'EFRONTMATTER' })).toHaveAttribute('data-tone', 'danger');
    await expect(page.locator('.problem-group', { hasText: 'WORPHAN' })).toHaveAttribute('data-tone', 'warn');
  });

  // `stale_reason` (#1068) names which stale fact the host means; an older
  // host without it leaves the shell to read `exit_code`. Both must agree.
  const startupStale: Json = {
    phase: 'stale', generation: 0, exit_code: null, used_stderr_fallback: false,
    message: 'Showing existing preview output from an earlier build; rebuild to refresh.', preview_url: 'https://preview.invalid/?token=test'
  };
  const failedStale: Json = {
    phase: 'stale', generation: 0, exit_code: 1, used_stderr_fallback: true,
    message: 'error: EFRONTMATTER: index.md:1:1: invalid field; last valid output is stale.', preview_url: 'https://preview.invalid/?token=test'
  };

  async function expectWarnThenFailure(page: Page, startup: Json, rebuilt: Json) {
    await installApi(page, { preview: startup });
    const state = page.locator('.preview-state');
    await expect(state).toContainText('stale:');
    await expect(state).toHaveAttribute('data-tone', 'warn');

    await page.route('**/api/preview/rebuild', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify(rebuilt) }));
    await page.getByRole('button', { name: 'Rebuild preview', exact: true }).click();
    await expect(state).toContainText('last valid output is stale');
    await expect(state).toHaveAttribute('data-tone', 'danger');
  }

  for (const host of [
    { name: 'host names stale_reason', startup: { stale_reason: 'earlier_build' }, failed: { stale_reason: 'failed_rebuild' } },
    { name: 'older host without stale_reason', startup: {}, failed: {} }
  ]) {
    test(`a startup stale preview is a warning; a stale preview after a failed rebuild is a failure (${host.name})`, async ({ page }) => {
      await expectWarnThenFailure(page, { ...startupStale, ...host.startup }, { ...failedStale, ...host.failed });
    });
  }

  test('stale_reason outranks exit_code: a timed-out rebuild with no exit code is still a failure', async ({ page }) => {
    const timedOut = { ...failedStale, exit_code: null, used_stderr_fallback: false, message: 'Boris preview build timed out; last valid output is stale.' };
    await expectWarnThenFailure(page, { ...startupStale, stale_reason: 'earlier_build' }, { ...timedOut, stale_reason: 'failed_rebuild' });
  });
});

/** WCAG relative-luminance contrast between two computed `rgb(...)` colors. */
function contrast(foreground: string, background: string): number {
  const channels = (color: string) => (color.match(/[\d.]+/g) ?? []).slice(0, 3).map(Number);
  const luminance = (color: string) => {
    const [r, g, b] = channels(color).map(value => {
      const c = value / 255;
      return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
    });
    return 0.2126 * r + 0.7152 * g + 0.0722 * b;
  };
  const [light, dark] = [luminance(foreground), luminance(background)].sort((a, b) => b - a);
  return (light + 0.05) / (dark + 0.05);
}

for (const theme of ['light', 'dark'] as const) {
  test(`primary buttons and their key hints stay readable in the ${theme} theme`, async ({ page }) => {
    await installApi(page, { theme });
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    // The Publication plan button shares a field row with a select; it must
    // keep the primary ink rather than inheriting a neighbour's muted one.
    const plan = page.getByRole('button', { name: 'Run publication plan', exact: true });
    const planColors = await plan.evaluate(el => ({ fg: getComputedStyle(el).color, bg: getComputedStyle(el).backgroundColor }));
    expect(contrast(planColors.fg, planColors.bg), 'Run publication plan label').toBeGreaterThanOrEqual(4.5);

    await page.getByRole('button', { name: 'Create file', exact: true }).click();
    const chip = page.getByRole('dialog', { name: 'Create file' }).locator('button.primary kbd');
    const chipColors = await chip.evaluate(el => ({ fg: getComputedStyle(el).color, bg: getComputedStyle(el).backgroundColor }));
    expect(contrast(chipColors.fg, chipColors.bg), 'primary key-hint chip').toBeGreaterThanOrEqual(4.5);
  });
}
