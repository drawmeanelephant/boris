import { expect, test, type Page } from '@playwright/test';

// Writing-surface e2e (#988, #989, #990, #991). Uses the same mocked-host
// approach as safe-editing.spec.ts: every endpoint is routed in-page, no Zig
// host is spawned.
//
// The suite pins three contracts:
//   1. Density modes: a cold open is the calm Author view (Source + Project);
//      Review restores the full chrome; the choice is disposable, persisted
//      per browser, and never touches the buffer.
//   2. Section navigation stays honest across modes: a target that lives in
//      the other mode switches modes and then lands; it is never disabled.
//   3. Writing chrome: the measured line gutter, the current-line band, and
//      the presentation-only frontmatter seam all track the buffer.
//   4. Problems action hierarchy: primary vs secondary groups, the busy
//      affordance, and collapsed large reports.

const FILES = [
  { path: 'boris.json' },
  { path: 'content/index.md' },
  { path: 'content/guides/frontmatter.md' }
];

const HOME_CONTENT = '---\nid: index\ntitle: Home\nparent: null\nstatus: published\n---\n\n# Home\n\nBody.\n';
const PLAIN_CONTENT = '# Home\n\nNo frontmatter here.\n';

type MockOptions = {
  mode?: 'author' | 'review';
  content?: string;
  commandDelayMs?: number;
  proofReport?: string | null;
};

type CommandResultShape = {
  mode: string;
  exit_code: number;
  failure_class: string;
  compiler_id: string;
  report_version: string | null;
  used_stderr_fallback: boolean;
  problems: Array<Record<string, unknown>>;
  findings: Array<Record<string, unknown>>;
  impact: Array<Record<string, unknown>>;
  publication_plan: Record<string, unknown> | null;
  recipe_scale_view: Record<string, unknown> | null;
  graph_document: string | null;
  proof_report: string | null;
};

function commandResult(mode: string, overrides: Partial<CommandResultShape> = {}): CommandResultShape {
  return {
    mode,
    exit_code: 0,
    failure_class: 'success',
    compiler_id: 'boris/0.8.2',
    report_version: null,
    used_stderr_fallback: false,
    problems: [],
    findings: [],
    impact: [],
    publication_plan: null,
    recipe_scale_view: null,
    graph_document: null,
    proof_report: null,
    ...overrides
  };
}

async function installApi(page: Page, options: MockOptions = {}) {
  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok',
      editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ compiler_id: 'boris/0.8.2' })
  }));
  await page.route('**/api/files', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ files: FILES })
  }));
  await page.route('**/api/recovery', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ snapshots: [], skipped: 0 })
  }));
  await page.route('**/api/recovery/snapshot', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'snapshotted' })
  }));
  await page.route('**/api/recovery/clear', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'cleared' })
  }));
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'unchanged', fingerprint: 'a'.repeat(64), read_only: false })
  }));
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'opened',
        path,
        content: options.content ?? HOME_CONTENT,
        fingerprint: 'a'.repeat(64),
        read_only: false
      })
    });
  });
  await page.route('**/api/commands/run', async route => {
    const { mode } = route.request().postDataJSON() as { mode: string };
    if (options.commandDelayMs) await new Promise(resolve => setTimeout(resolve, options.commandDelayMs));
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify(commandResult(mode, { proof_report: options.proofReport ?? null }))
    });
  });
  await page.route('**/api/authoring', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: { id: { type: 'string' } } },
      completion: null,
      completion_status: 'build_required'
    })
  }));
  await page.route('**/api/graph', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ graph: null, graph_status: 'build_required' })
  }));
  await page.route('**/api/publication', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ profiles: [{ path: 'boris.json' }], proof: null })
  }));
  await page.route('**/api/preview/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false,
      message: 'Preview has not been built yet.', preview_url: 'https://preview.invalid/?token=test'
    })
  }));
  await page.route('**/api/watch/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      supported: false, state: 'idle', seq: 0, cycle: 0, events_count: 0, oldest_seq: null,
      dropped_lines: 0, last_event: null, compiler_id: null, hello_schema: null, last_error: null
    })
  }));
  for (const endpoint of ['start', 'stop']) {
    await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({
      status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
    }));
  }
  await page.route(/\/api\/watch\/events/, route => route.fulfill({
    status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
  }));
  if (options.mode) {
    await page.addInitScript((mode: string) => localStorage.setItem('boris-editor-density', mode), options.mode);
  }
  await page.goto('/#token=test-session-token');
}

function densityToggle(page: Page) {
  return page.getByRole('group', { name: 'Editor density' });
}

async function openHome(page: Page) {
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
  return page.getByRole('textbox', { name: 'Source for content/index.md' });
}

async function switchToReview(page: Page) {
  await densityToggle(page).getByRole('button', { name: 'Review', exact: true }).click();
  await expect(page.locator('#problems')).toBeVisible();
}

test('a cold open is the calm Author view with Source as the writing surface', async ({ page }) => {
  await installApi(page);
  const editor = await openHome(page);

  // Author is selected and the review panes are not mounted at all — they
  // cannot pretend to be present.
  await expect(densityToggle(page).getByRole('button', { name: 'Author', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(densityToggle(page).getByRole('button', { name: 'Review', exact: true })).toHaveAttribute('aria-pressed', 'false');
  await expect(page.locator('.workspace-rail')).toHaveCount(0);
  await expect(page.locator('#problems')).toHaveCount(0);
  await expect(page.locator('#preview')).toHaveCount(0);
  await expect(page.locator('#watch')).toHaveCount(0);
  await expect(page.locator('#publication')).toHaveCount(0);

  // The writing surface keeps its accessible name and the authoring hints are
  // folded to one disclosure instead of a second card under the editor.
  await expect(editor).toBeVisible();
  const hints = page.locator('details.authoring-collapse');
  await expect(hints).toBeVisible();
  await expect(hints).not.toHaveAttribute('open', '');
  await expect(hints.locator(':scope > summary')).toHaveText('Boris authoring hints');
});

test('Author gives the writing surface more height, and the buffer survives both toggles', async ({ page }) => {
  await installApi(page);
  const editor = await openHome(page);
  await editor.fill('# Draft\n\nUnsaved line.\n');
  const authorHeight = (await editor.boundingBox())!.height;

  await switchToReview(page);
  const reviewHeight = (await editor.boundingBox())!.height;
  expect(authorHeight).toBeGreaterThan(reviewHeight + 60);
  await expect(editor).toHaveValue('# Draft\n\nUnsaved line.\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();

  await densityToggle(page).getByRole('button', { name: 'Author', exact: true }).click();
  await expect(page.locator('#problems')).toHaveCount(0);
  await expect(editor).toHaveValue('# Draft\n\nUnsaved line.\n');
  await expect(page.getByText('Unsaved changes', { exact: true })).toBeVisible();
});

test('the density choice is disposable editor state that survives a reload', async ({ page }) => {
  await installApi(page);
  await switchToReview(page);
  await page.reload();
  await expect(page.locator('#problems')).toBeVisible();
  await expect(densityToggle(page).getByRole('button', { name: 'Review', exact: true })).toHaveAttribute('aria-pressed', 'true');

  await densityToggle(page).getByRole('button', { name: 'Author', exact: true }).click();
  await expect(page.locator('#problems')).toHaveCount(0);
  await page.reload();
  await expect(page.locator('#problems')).toHaveCount(0);
  await expect(densityToggle(page).getByRole('button', { name: 'Author', exact: true })).toHaveAttribute('aria-pressed', 'true');
});

test('a nav link to a pane in the other mode switches modes and lands there', async ({ page }) => {
  await installApi(page);
  const problems = page.getByRole('navigation', { name: 'Editor sections' }).getByRole('link', { name: 'Problems', exact: true });
  // Honest, not disabled: the target is available, just in Review.
  await expect(problems).not.toHaveAttribute('aria-disabled');
  await expect(problems).toHaveClass(/mode-gated/);
  await problems.click();

  await expect(densityToggle(page).getByRole('button', { name: 'Review', exact: true })).toHaveAttribute('aria-pressed', 'true');
  await expect(page.locator('#problems')).toBeVisible();
  await expect(page.locator('#problems')).toBeFocused();
  await expect(page.locator('#problems')).toHaveClass(/arrived/, { timeout: 2_000 });
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Switched to Review mode');
});

test('a reduced-motion reveal keeps aria-current on the landed target at max scroll', async ({ page }) => {
  // QA repro: a mode-gated reveal grows the page (Review mounts the Graph
  // pane), the jump clamps at max scroll, and the reading line falls inside
  // the Graph pane. The landed target must keep its active marker instead of
  // the spy's bottom rule handing it to the last present pane.
  await page.setViewportSize({ width: 1280, height: 720 });
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await installApi(page);
  await openHome(page);

  const graph = page.getByRole('navigation', { name: 'Editor sections' }).getByRole('link', { name: 'Graph', exact: true });
  await graph.click();
  await expect(page.locator('#graph')).toBeFocused();
  await expect(graph).toHaveAttribute('aria-current', 'true');

  // Settled state, after the spy's 600 ms resync: the target still owns
  // wayfinding and no other link claims it.
  await page.waitForTimeout(800);
  await expect(graph).toHaveAttribute('aria-current', 'true');
  await expect(page.getByRole('navigation', { name: 'Editor sections' }).getByRole('link', { name: 'Watch', exact: true }))
    .not.toHaveAttribute('aria-current');
});

test('the measured line gutter and current-line band track the caret', async ({ page }) => {
  await installApi(page);
  const editor = await openHome(page);

  // Line 1 is current on open; the band and the rail number agree.
  await expect(page.locator('.source-gutter-line.current')).toHaveText('1');
  const band = page.locator('.source-current-line');
  await expect(band).toHaveCount(1);
  const firstTop = await band.evaluate(el => Number.parseFloat((el as HTMLElement).style.top));

  // Move the caret to a later line and let the select event update state.
  await editor.evaluate((el: HTMLTextAreaElement) => {
    const offset = el.value.indexOf('# Home');
    el.focus();
    el.setSelectionRange(offset, offset);
    el.dispatchEvent(new Event('select'));
  });
  await expect(page.locator('.source-gutter-line.current')).toHaveText('8');
  await expect(page.locator('.source-caret')).toContainText('Line 8');
  const laterTop = await page.locator('.source-current-line').evaluate(el => Number.parseFloat((el as HTMLElement).style.top));
  expect(laterTop).toBeGreaterThan(firstTop);

  // The frontmatter seam is drawn once, for the recognized leading fence
  // shape; it is presentation, so it lives outside the accessibility tree.
  const seam = page.locator('.source-frontmatter-seam');
  await expect(seam).toHaveCount(1);
  await expect(seam.locator('.source-seam-label')).toHaveText('frontmatter ends');
  await expect(page.locator('.source-gutter')).toHaveAttribute('aria-hidden', 'true');
  await expect(page.locator('.source-mirror')).toHaveAttribute('aria-hidden', 'true');
});

test('a buffer without a frontmatter fence gets no seam', async ({ page }) => {
  await installApi(page, { content: PLAIN_CONTENT });
  await openHome(page);
  await expect(page.locator('.source-frontmatter-seam')).toHaveCount(0);
  await expect(page.locator('.source-current-line')).toHaveCount(1);
});

test('the measured gutter follows a long buffer while scrolling', async ({ page }) => {
  const long = Array.from({ length: 200 }, (_, index) => `line ${index + 1} of a long document`).join('\n');
  await installApi(page, { content: long });
  const editor = await openHome(page);

  const scrollTop = await editor.evaluate((el: HTMLTextAreaElement) => {
    el.scrollTop = el.scrollHeight;
    return el.scrollTop;
  });
  await expect(page.locator('.source-gutter-inner')).toContainText('200');
  // The gutter layer shares the textarea's scroll offset, so the measured
  // numbers stay glued to their lines.
  await expect(page.locator('.source-gutter-inner')).toHaveCSS('transform', `matrix(1, 0, 0, 1, 0, ${-scrollTop})`);
});

test('Problems leads with primary actions and keeps analysis in a secondary group', async ({ page }) => {
  await installApi(page, { mode: 'review' });
  const problems = page.locator('#problems');
  await openHome(page);

  const buildGroup = problems.getByRole('group', { name: 'Build and validate' });
  const analysisGroup = problems.getByRole('group', { name: 'Analysis' });
  await expect(buildGroup.getByRole('button', { name: 'Validate project', exact: true })).toHaveClass(/primary/);
  await expect(buildGroup.getByRole('button', { name: 'Build diagnostics', exact: true })).toHaveClass(/primary/);
  await expect(buildGroup.getByRole('button', { name: 'Build HTML', exact: true })).toBeVisible();
  await expect(analysisGroup.getByRole('button', { name: 'Check graph', exact: true })).toBeVisible();
  await expect(analysisGroup.getByRole('button', { name: 'Verify proof', exact: true })).toBeVisible();
  await expect(analysisGroup.getByRole('button', { name: 'Check graph', exact: true })).not.toHaveClass(/primary/);
});

test('the running command carries aria-busy and an in-button progress affordance', async ({ page }) => {
  await installApi(page, { mode: 'review', commandDelayMs: 150 });
  const problems = page.locator('#problems');
  await openHome(page);

  const diagnostics = problems.getByRole('button', { name: 'Build diagnostics', exact: true });
  await diagnostics.click();
  await expect(diagnostics).toHaveAttribute('aria-busy', 'true');
  await expect(diagnostics).toHaveClass(/is-running/);
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('Running Build diagnostics');
  await expect(diagnostics).not.toHaveAttribute('aria-busy', 'true', { timeout: 5_000 });
  await expect(page.getByRole('status', { name: 'Boris command status' })).toContainText('finished');
});

test('the command palette still lists the secondary commands', async ({ page }) => {
  await installApi(page, { mode: 'review' });
  await openHome(page);
  await page.keyboard.press('Control+k');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  await expect(palette.getByRole('option', { name: /^Check graph/ })).toBeVisible();
  await expect(palette.getByRole('option', { name: /^Verify proof/ })).toBeVisible();
  await expect(palette.getByRole('option', { name: /^Run impact;/ })).toBeVisible();
});

test('a large proof report starts collapsed behind an explicit disclosure', async ({ page }) => {
  const report = Array.from({ length: 40 }, (_, index) => `verify line ${index + 1}`).join('\n');
  await installApi(page, { mode: 'review', proofReport: report });
  const problems = page.locator('#problems');
  await openHome(page);
  await problems.getByRole('button', { name: 'Verify proof', exact: true }).click();

  const details = problems.locator('details.report-details');
  await expect(details).toBeVisible();
  await expect(details.locator('summary')).toHaveText('Show proof verify report (40 lines)');
  await expect(details.locator('pre')).toBeHidden();
  await details.locator('summary').click();
  await expect(details.locator('pre')).toContainText('verify line 40');
});
