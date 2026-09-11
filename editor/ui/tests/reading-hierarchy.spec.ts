import { expect, test, type Page } from '@playwright/test';

// Reading-hierarchy conformance (#418 readability pass). The editor's
// chrome drifted into "everything is 16px" — a sub-pane heading even rendered
// larger than the pane title above it, because unstyled h3 inherits the user
// agent's 1.17em. These assertions pin the invariants that fix that, plus the
// two real layout defects the pass found:
//
//   1. a pane title reads as a heading over body copy;
//   2. heading levels never invert (app > pane > sub-pane > body > labels);
//   3. ledes and field labels stay one step below body copy;
//   4. the Problems result chip never squeezes its lede into a word-per-line
//      column (it wraps to its own line instead);
//   5. a pane's action cluster never overflows its own section box — the
//      overflow painted the cluster over the neighbouring pane, which is how
//      it surfaced: a non-shrinking cluster made the Project pane's Delete
//      file button land under #source and fail pointer interception.
//
// Sizes are read from computed styles, not from the stylesheet, so a token
// edit that breaks the chain fails here rather than in a screenshot review.

const BODY_REM = 16;

const FILES = [
  { path: 'boris.json' },
  { path: 'content/index.md' },
  { path: 'content/guides/frontmatter.md' },
  { path: 'themes/boris/layouts/default.html' }
];

const PROBLEM = {
  severity: 'error',
  code: 'EFRONTMATTER',
  message: "unknown frontmatter key 'parent_entry'",
  remediation: 'Rename the key to `parent`, or remove it.',
  source_path: 'content/index.md',
  line: 4,
  column: 1,
  id: 'index',
  origin: 'build_report',
  position_confidence: 'exact',
  packet: '{"code":"EFRONTMATTER"}'
};

async function installApi(page: Page) {
  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'ok', editor_id: 'boris-editor/0.1.0', project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' } })
  }));
  await page.route('**/api/version', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ compiler_id: 'boris/0.8.2' }) }));
  await page.route('**/api/files', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ files: FILES }) }));
  await page.route('**/api/recovery', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ snapshots: [], skipped: 0 }) }));
  await page.route('**/api/recovery/snapshot', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ status: 'snapshotted' }) }));
  await page.route('**/api/recovery/clear', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ status: 'cleared' }) }));
  await page.route('**/api/files/probe', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'unchanged', fingerprint: 'a'.repeat(64), read_only: false })
  }));
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        status: 'opened', path,
        content: '---\nid: index\ntitle: Home\nparent: null\nstatus: published\n---\n\n# Home\n\nBody.\n',
        fingerprint: 'a'.repeat(64), read_only: false
      })
    });
  });
  await page.route('**/api/commands/run', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      mode: 'validate', exit_code: 1, failure_class: 'content', compiler_id: 'boris/0.8.2',
      report_version: 'html-build-report-0.2.0', used_stderr_fallback: false,
      problems: [PROBLEM], findings: [], impact: []
    })
  }));
  await page.route('**/api/validate-state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ supported: true, state: 'failed', cycle: 3, failure_class: 'content', problems_count: 1, report_age_ms: 1200 })
  }));
  await page.route('**/api/authoring', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: { id: { type: 'string' }, title: { type: 'string' } } },
      completion: null, completion_status: 'build_required'
    })
  }));
  await page.route('**/api/graph', route => route.fulfill({ contentType: 'application/json', body: JSON.stringify({ graph: null, graph_status: 'build_required' }) }));
  await page.route('**/api/publication', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ profiles: [{ path: 'boris.json' }], proof: null })
  }));
  await page.route('**/api/preview/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false, message: 'Preview has not been built yet.', preview_url: 'https://preview.invalid/?token=test' })
  }));
  await page.route('**/api/watch/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ supported: true, state: 'idle', seq: 0, cycle: 0, events_count: 0, oldest_seq: null, dropped_lines: 0, last_event: null, compiler_id: 'boris/0.8.2', hello_schema: null, last_error: null })
  }));
  await page.route(/\/api\/watch\/events/, route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ supported: true, seq: 0, oldest_seq: null, gap: false, events: [] })
  }));
  for (const endpoint of ['start', 'stop']) {
    await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({
      contentType: 'application/json', body: JSON.stringify({ status: endpoint === 'start' ? 'started' : 'stopped' })
    }));
  }
  await page.goto('/#token=test-session-token');
}

/** Computed font-size in px for a selector. */
async function fontSize(page: Page, selector: string): Promise<number> {
  return page.locator(selector).first().evaluate(el => Number.parseFloat(getComputedStyle(el).fontSize));
}

/** Box and line metrics for a locator, so line counting stays honest. */
async function chipGeometry(locator: ReturnType<Page['locator']>) {
  return locator.evaluate(el => ({
    width: el.getBoundingClientRect().width,
    height: el.getBoundingClientRect().height,
    lineHeight: Number.parseFloat(getComputedStyle(el).lineHeight),
    whiteSpace: getComputedStyle(el).whiteSpace
  }));
}


async function openHome(page: Page) {
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
}

for (const width of [1440, 1024]) {
  test(`heading levels never invert at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await installApi(page);
    await openHome(page);
    await page.getByRole('button', { name: 'Validate project' }).click();
    await expect(page.locator('.command-result')).toBeVisible();

    const h1 = await fontSize(page, 'h1');
    const paneTitle = await fontSize(page, '#problems-heading');
    const subPaneTitle = await fontSize(page, '#authoring-heading');
    const body = BODY_REM;
    const lede = await fontSize(page, '#problems-heading + p');
    const groupLabel = await fontSize(page, '.problem-group h3');
    const fieldLabel = await fontSize(page, 'label[for="file-filter"]');

    // 1. A pane title reads as a heading over body copy, not as slightly
    //    bigger text.
    expect(paneTitle).toBeGreaterThanOrEqual(body * 1.25);
    // 2. The order holds at every level. The sub-pane title sitting *above*
    //    the pane title is the exact regression this pass fixed (unstyled h3
    //    at 1.17em rendered 18.72px against a styled 18.4px h2).
    expect(h1).toBeGreaterThan(paneTitle);
    expect(paneTitle).toBeGreaterThan(subPaneTitle);
    expect(subPaneTitle).toBeGreaterThan(body);
    // 3. Copy that explains a heading stays a step below it. The group label
    //    inside a problem card is an h3 too, but it is a label band rather
    //    than a title, so it must not exceed the pane title.
    expect(groupLabel).toBeLessThanOrEqual(paneTitle);
    expect(lede).toBeLessThan(body);
    expect(fieldLabel).toBeLessThan(body);

    // Prose has a real line-height rather than the browser default.
    const leading = await page.locator('#problems-heading + p').first()
      .evaluate(el => Number.parseFloat(getComputedStyle(el).lineHeight) / Number.parseFloat(getComputedStyle(el).fontSize));
    expect(leading).toBeGreaterThanOrEqual(1.4);
  });
}

test('the Problems result chip wraps instead of squeezing the lede', async ({ page }) => {
  await page.setViewportSize({ width: 1280, height: 900 });
  await installApi(page);
  await openHome(page);
  await page.getByRole('button', { name: 'Validate project' }).click();
  const chip = page.locator('.command-result');
  await expect(chip).toBeVisible();

  const ledeWidth = await page.locator('#problems-heading + p').first().evaluate(el => el.getBoundingClientRect().width);
  const chipBox = await chipGeometry(chip);
  // The lede keeps a real reading measure; before the shared header row it
  // collapsed to roughly the chip's width and wrapped at a few words a line.
  expect(ledeWidth).toBeGreaterThan(260);
  expect(ledeWidth).toBeGreaterThan(chipBox.width);
  // The chip stays on one line — it is a badge, not wrapped prose. With
  // `nowrap` its height is one line plus vertical padding and border; a
  // wrapped two-line chip would be roughly twice that.
  expect(chipBox.whiteSpace).toBe('nowrap');
  expect(chipBox.height).toBeLessThan(chipBox.lineHeight + 24);
});

for (const width of [1440, 1280, 1024]) {
  test(`no pane header cluster overflows its section at ${width}px`, async ({ page }) => {
    await page.setViewportSize({ width, height: 900 });
    await installApi(page);
    await openHome(page);
    // Both panes that carry a wide cluster: Project (create/rename/delete)
    // and Source (focus/undo/redo/save).
    await page.getByRole('button', { name: 'Validate project' }).click();
    await expect(page.locator('.command-result')).toBeVisible();

    const overflows = await page.evaluate(() => {
      const findings: string[] = [];
      for (const heading of Array.from(document.querySelectorAll('.pane-heading'))) {
        const section = heading.closest('section');
        if (!section) continue;
        const style = getComputedStyle(section);
        const padRight = Number.parseFloat(style.paddingRight);
        const padLeft = Number.parseFloat(style.paddingLeft);
        const box = section.getBoundingClientRect();
        const contentRight = box.right - padRight;
        const contentLeft = box.left + padLeft;
        const label = section.id || section.className;
        for (const child of Array.from(heading.children)) {
          const rect = child.getBoundingClientRect();
          if (rect.right > contentRight + 1 || rect.left < contentLeft - 1) {
            findings.push(`${label}: ${(child as HTMLElement).className} spans ${Math.round(rect.left)}–${Math.round(rect.right)} vs content ${Math.round(contentLeft)}–${Math.round(contentRight)}`);
          }
        }
      }
      return { findings, docScrollWidth: document.documentElement.scrollWidth, innerWidth: window.innerWidth };
    });

    expect(overflows.findings).toEqual([]);
    // And nothing pushes the document sideways either.
    expect(overflows.docScrollWidth).toBeLessThanOrEqual(overflows.innerWidth);
  });
}
