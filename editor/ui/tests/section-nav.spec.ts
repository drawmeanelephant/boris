import { expect, test, type Page } from '@playwright/test';

// Section nav feedback e2e (#941): arrival highlight, scrollspy
// aria-current, sticky reachability, focus hand-off, and the mobile edge
// affordance. Same mocked-host approach as the other suites: every endpoint
// is routed in-page, no Zig host is spawned. Sticky positioning itself is a
// browser layout behavior; the e2e asserts the functional contract (the nav
// stays visible and operable at any scroll depth and links keep their
// roles/names, which safe-editing.spec.ts pins).

type InstallOptions = {
  /** Launch `open=` param: a cold-launch URL opens this file at connect. */
  open?: string;
};

async function installApi(page: Page, options: InstallOptions = {}) {
  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok', editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ compiler_id: 'boris/0.8.2' })
  }));
  await page.route('**/api/files', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ files: [{ path: 'boris.json' }, { path: 'content/index.md' }] })
  }));
  await page.route('**/api/recovery', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ snapshots: [], skipped: 0 })
  }));
  await page.route('**/api/recovery/snapshot', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ status: 'snapshotted' })
  }));
  await page.route('**/api/recovery/clear', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ status: 'cleared' })
  }));
  await page.route('**/api/files/probe', async route => {
    const body = route.request().postDataJSON() as { fingerprint?: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'unchanged', fingerprint: body.fingerprint ?? 'a'.repeat(64), read_only: false })
    });
  });
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'opened', path, content: '# Home\n', fingerprint: 'a'.repeat(64), read_only: false })
    });
  });
  await page.route('**/api/files/save', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ status: 'saved', path: 'content/index.md', content: '# Home\n', fingerprint: 'c'.repeat(64), read_only: false })
  }));
  await page.route('**/api/commands/run', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      mode: 'validate', exit_code: 0, failure_class: 'success', compiler_id: 'boris/0.8.2',
      report_version: null, used_stderr_fallback: false, problems: [], findings: [], impact: []
    })
  }));
  await page.route('**/api/validate-state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ supported: false, state: 'idle', cycle: 0, failure_class: null, problems_count: 0 })
  }));
  for (const endpoint of ['state', 'start', 'stop']) {
    await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({
      status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
    }));
  }
  await page.route(/\/api\/watch\/events/, route => route.fulfill({
    status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
  }));
  await page.route('**/api/authoring', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: {} }, completion: null, completion_status: 'build_required' })
  }));
  await page.route('**/api/graph', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ graph: null, graph_status: 'build_required' })
  }));
  await page.route('**/api/publication', route => route.fulfill({
    contentType: 'application/json', body: JSON.stringify({ profiles: [{ path: 'boris.json' }], proof: null })
  }));
  await page.route('**/api/preview/state', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      phase: 'idle', generation: 0, exit_code: null, used_stderr_fallback: false,
      message: 'Preview has not been built yet.',
      preview_url: 'https://preview.invalid/?token=test'
    })
  }));
  await page.route('**/api/preview/rebuild', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      phase: 'success', generation: 1, exit_code: 0, used_stderr_fallback: false,
      message: 'Preview is current from a successful Boris incremental build.',
      preview_url: 'https://preview.invalid/?token=test'
    })
  }));
  await page.route('https://preview.invalid/**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Compiler output</h1>' }));
  // Launch fragment: token always present; open= exercises the consumed
  // launch-open path (#943).
  const launchParams = new URLSearchParams({ token: 'test-session-token' });
  if (options.open) launchParams.set('open', options.open);
  await page.goto(`/#${launchParams.toString()}`);
}

function navLink(page: Page, name: string) {
  return page.getByRole('navigation', { name: 'Editor sections' }).getByRole('link', { name, exact: true });
}

// A jump writes currency to the target synchronously, then animates (smooth
// scroll) and re-asserts viewport truth — per scroll frame and again on the
// component's 600ms fallback timer. An assertion made straight after the
// click therefore samples the pre-scroll instant value, not the settled one.
// Hold until both scroll containers are still and the resync window has
// passed, so the currency assertion reads the verdict the author ends on.
async function waitForJumpToSettle(page: Page) {
  await page.waitForFunction(() => new Promise<boolean>((resolve) => {
    const rail = document.querySelector('.workspace-rail');
    const start = performance.now();
    let lastY = window.scrollY;
    let lastRail = rail ? rail.scrollTop : 0;
    let still = 0;
    const step = () => {
      const y = window.scrollY;
      const r = rail ? rail.scrollTop : 0;
      still = y === lastY && r === lastRail ? still + 1 : 0;
      lastY = y;
      lastRail = r;
      if (still >= 10 && performance.now() - start >= 700) resolve(true);
      else requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }));
}

test('nav click jumps, focuses the target section, and pulses the arrival highlight', async ({ page }) => {
  await installApi(page);
  await navLink(page, 'Problems').click();
  const problems = page.locator('#problems');
  await expect(problems).toBeFocused();
  await expect(problems).toHaveClass(/arrived/, { timeout: 2_000 });

  // Highlight is transient.
  await expect(problems).not.toHaveClass(/arrived/, { timeout: 3_000 });
  // The URL reflects the section without a native hash navigation, and the
  // launch token rides along (#943).
  const params = new URLSearchParams(new URL(page.url()).hash.slice(1));
  expect(params.get('section')).toBe('problems');
  expect(params.get('token')).toBe('test-session-token');
  // Focus hand-off: the next Tab continues from the landed section.
  await page.keyboard.press('Tab');
  await expect(page.locator('#problems').getByRole('button').first()).toBeFocused();
});

test('rapid nav clicks move the arrival highlight to the newest target', async ({ page }) => {
  await installApi(page);
  await navLink(page, 'Watch').click();
  await expect(page.locator('#watch')).toHaveClass(/arrived/, { timeout: 2_000 });
  await navLink(page, 'Preview').click();
  await expect(page.locator('#preview')).toHaveClass(/arrived/, { timeout: 2_000 });
  await expect(page.locator('#watch')).not.toHaveClass(/arrived/);
});

test('scrollspy keeps aria-current on the section at the reading top', async ({ page }) => {
  await installApi(page);
  const nav = page.getByRole('navigation', { name: 'Editor sections' });
  await expect(nav.locator('a[aria-current="true"]')).toHaveText(/Project|Source/);

  await navLink(page, 'Problems').click();
  await expect(navLink(page, 'Problems')).toHaveAttribute('aria-current', 'true');
  await expect(navLink(page, 'Project')).not.toHaveAttribute('aria-current');

  // Jumping to the last section stays current even where the page clamps:
  // a short document can never park Watch under the nav, so the spy's
  // bottom rule must hand currency over regardless of geometry. The smooth
  // scroll animates through intermediate sections, so this must poll.
  await navLink(page, 'Watch').click();
  await expect(navLink(page, 'Watch')).toHaveAttribute('aria-current', 'true');

  // Back to the top hands currency back to the leading section. Both scroll
  // containers must reset: at wide viewports the workspace rail scrolls
  // internally, and leaving it offset keeps rail panes pinned at the
  // viewport top in viewport coordinates — where the spy would honestly
  // report them. Polled, because the smooth scroll fires scroll events
  // across several frames.
  await page.evaluate(() => {
    window.scrollTo(0, 0);
    document.querySelector('.workspace-rail')?.scrollTo(0, 0);
  });
  await expect(nav.locator('a[aria-current="true"]')).toHaveAttribute('href', /#(project|source)/);
});

test('scrolling inside the workspace rail moves aria-current with no window scroll', async ({ page }) => {
  await installApi(page);
  // Wide viewport so the rail is its own scroll container (≥80rem rule).
  await page.setViewportSize({ width: 1440, height: 720 });
  const nav = page.getByRole('navigation', { name: 'Editor sections' });

  // Page top, rail untouched: the leading section owns the reading line.
  await expect(navLink(page, 'Project')).toHaveAttribute('aria-current', 'true');

  // Rail-internal scroll alone brings a rail section onto the reading line;
  // the spy must follow with zero window scroll (fails on a window-only
  // listener — #942 review finding 1), then follow back on reset.
  await page.evaluate(() => {
    const rail = document.querySelector('.workspace-rail');
    rail?.scrollTo(0, rail.scrollHeight);
  });
  await expect(nav.locator('a[aria-current="true"]')).toHaveAttribute('href', /#(preview|watch)/);
  await page.evaluate(() => document.querySelector('.workspace-rail')?.scrollTo(0, 0));
  await expect(navLink(page, 'Project')).toHaveAttribute('aria-current', 'true');
  expect(await page.evaluate(() => window.scrollY)).toBe(0);
});

test('nav stays reachable while scrolled and keyboard activation works', async ({ page }) => {
  await installApi(page);
  await page.locator('#watch').scrollIntoViewIfNeeded();
  const nav = page.getByRole('navigation', { name: 'Editor sections' });
  await expect(nav).toBeVisible();
  // Keyboard activation of a nav link follows the same hand-off path.
  await navLink(page, 'Problems').focus();
  await page.keyboard.press('Enter');
  await expect(page.locator('#problems')).toBeFocused();
});

test('arrival highlight collapses to a static cue under reduced motion', async ({ page }) => {
  await installApi(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  const watch = page.locator('#watch');
  await navLink(page, 'Watch').click();
  // The class (the attention cue) still applies...
  await expect(watch).toHaveClass(/arrived/, { timeout: 2_000 });
  // ...and the jump is instant, not smooth. #watch is the last section, so
  // the jump may be clamped at max scroll (the footer plus viewport cannot
  // park it under the nav) — the honest assertion is the rest state: parked
  // under the nav or exactly at max scroll.
  const landed = await page.evaluate(() => {
    const el = document.getElementById('watch');
    if (!el) return false;
    const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
    const atMax = Math.abs(window.scrollY - maxScroll) < 2;
    const margin = parseFloat(getComputedStyle(el).scrollMarginTop) || 0;
    const navHeight = document.querySelector('.section-nav')?.getBoundingClientRect().height ?? 0;
    const parked = Math.abs(el.getBoundingClientRect().top - (navHeight + margin)) < 2;
    return atMax || parked;
  });
  expect(landed).toBe(true);
  await expect(watch).not.toHaveClass(/arrived/, { timeout: 3_000 });
});

test('mobile pill row scrolls and the active pill stays reachable', async ({ page }) => {
  await installApi(page);
  await page.setViewportSize({ width: 480, height: 800 });
  const nav = page.getByRole('navigation', { name: 'Editor sections' });
  const row = nav.locator('.section-nav-row');
  await expect(row).toHaveCSS('overflow-x', 'auto');
  // The narrow viewport must actually need scrolling for this assertion to
  // mean anything.
  expect(await row.evaluate(el => el.scrollWidth > el.clientWidth)).toBe(true);
  await navLink(page, 'Watch').click();
  await expect(page.locator('#watch')).toHaveClass(/arrived/, { timeout: 2_000 });
  // The active pill was auto-scrolled into the visible strip. Polled: the
  // arrival class lands instantly, but the smooth jump is still animating
  // and currency (hence the row's scroll position) settles only at the
  // end of the scroll — poll for the end state, not a mid-flight frame.
  await expect.poll(async () => row.evaluate(el => {
    const link = el.querySelector('a[href="#watch"]');
    if (!link) return false;
    const a = link.getBoundingClientRect();
    const r = el.getBoundingClientRect();
    return a.left >= r.left - 1 && a.right <= r.right + 1;
  })).toBe(true);
  // An edge bar shows on the untouched side; the worked-through side clears.
  await expect(nav.locator('.section-nav-fade-start')).toHaveCSS('opacity', '1');
});

test('nav target ids are unique in both pane states', async ({ page }) => {
  await installApi(page);
  // Empty state: SourcePane renders its graph empty-state section (#941's
  // historical duplicate of #graph) — the real GraphPane is absent here.
  const ids = ['project', 'source', 'graph', 'graph-empty', 'publication', 'problems', 'preview', 'watch'];
  let duplicates = await page.evaluate(ids => {
    return ids.filter(id => document.querySelectorAll(`[id="${id}"]`).length > 1);
  }, ids);
  expect(duplicates).toEqual([]);
  await expect(page.locator('#graph-empty')).toHaveCount(1);
  await expect(page.locator('#graph')).toHaveCount(0);

  // Open state: the real GraphPane replaces the empty state.
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
  duplicates = await page.evaluate(ids => {
    return ids.filter(id => document.querySelectorAll(`[id="${id}"]`).length > 1);
  }, ids);
  expect(duplicates).toEqual([]);
  await expect(page.locator('#graph')).toHaveCount(1);
  await expect(page.locator('#graph-empty')).toHaveCount(0);
});

test('nav click preserves the token and drops the consumed open param (#943)', async ({ page }) => {
  await installApi(page);
  await navLink(page, 'Problems').click();
  await expect(page.locator('#problems')).toHaveClass(/arrived/, { timeout: 2_000 });

  // The fragment keeps the session token and records the live section;
  // the section id must be the fragment's last param.
  const params = new URLSearchParams(new URL(page.url()).hash.slice(1));
  expect(params.get('token')).toBe('test-session-token');
  expect(params.get('section')).toBe('problems');
  const keys = Array.from(params.keys());
  expect(keys[keys.length - 1]).toBe('section');

  // Reload lands in an authenticated editor (the native guard for a
  // token-wiping URL write), and the section jump is NOT reapplied — the
  // component's spy handles positioning, not launch parsing.
  await page.reload();
  await expect(page.getByRole('status', { name: 'Connection status' })).toContainText('Connected to boris-editor');
});

test('the open= launch param is consumed and not resurrected by nav clicks', async ({ page }) => {
  await installApi(page, { open: 'content/index.md' });
  // Cold launch: the host-open request carried the launch path.
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();

  await navLink(page, 'Problems').click();
  const params = new URLSearchParams(new URL(page.url()).hash.slice(1));
  expect(params.get('open')).toBeNull();
  expect(params.get('token')).toBe('test-session-token');

  // Reload: no surprise reopen — the editor comes up with no file loaded.
  await page.reload();
  await expect(page.getByRole('textbox', { name: /Source for/ })).toHaveCount(0);
  await expect(page.getByRole('status', { name: 'Connection status' })).toContainText('Connected to boris-editor');
});

test('the Graph nav link is honestly disabled while no file is open (#944)', async ({ page }) => {
  await installApi(page);
  const graph = navLink(page, 'Graph');
  await expect(graph).toHaveAttribute('aria-disabled', 'true');
  await expect(graph).toHaveAttribute('title', 'Graph is available once a file is open.');
  // An absent section can never be current.
  await expect(graph).not.toHaveAttribute('aria-current');

  // Activation is a no-op that explains itself via the editing status —
  // no jump, no arrival pulse, no URL write. force: because Playwright's
  // actionability check refuses aria-disabled elements, while a real
  // user's click still fires the handler.
  await graph.click({ force: true });
  await expect(page.locator('#graph')).toHaveCount(0);
  await expect(page.locator('#graph-empty')).toBeVisible();
  await expect(page.locator('.section-nav')).toHaveAttribute('data-arrived', '');
  expect(new URL(page.url()).hash).not.toContain('section=graph');
  await expect(page.getByRole('status', { name: 'Editing status' })).toContainText('Graph is available once a file is open.');
});

test('the Graph nav link returns to full behavior once a file is open', async ({ page }) => {
  await installApi(page);
  await expect(navLink(page, 'Graph')).toHaveAttribute('aria-disabled', 'true');

  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
  const graph = navLink(page, 'Graph');
  await expect(graph).not.toHaveAttribute('aria-disabled');

  await graph.click();
  await expect(page.locator('#graph')).toHaveClass(/arrived/, { timeout: 2_000 });
  // Settled, not the instant pre-scroll write: the spy must still name Graph
  // after the jump animates and the 600ms resync fires.
  await waitForJumpToSettle(page);
  await expect(graph).toHaveAttribute('aria-current', 'true');
});

test('a jump keeps currency on the target after the resync window', async ({ page }) => {
  // Reduced motion makes the jump instant, so nothing animates: the only
  // thing that can move currency after the click is the component's 600ms
  // resync. The panes sit in separate columns, so a section that is later in
  // nav order can be positioned above the reading line — that section must
  // not steal currency from the target the author actually jumped to.
  await installApi(page);
  await page.emulateMedia({ reducedMotion: 'reduce' });
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
  const graph = navLink(page, 'Graph');
  await graph.click();
  await waitForJumpToSettle(page);
  await expect(graph).toHaveAttribute('aria-current', 'true');
});

// The panes occupy different columns per breakpoint: one track at mobile,
// two plus a full-width rail below the desktop breakpoint, and three at
// >=80rem (Project / Source, with Graph and Publication nested inside Source,
// / rail). Nav order is therefore NOT visual order at desktop widths — a
// section later in nav order can sit higher on screen, or land at the same
// reading offset in another column. Currency must still follow the pane the
// author jumped to, in every layout; this pins that contract so a future
// pane that breaks the order-versus-layout relationship fails here loudly
// instead of silently mislabelling the active pane.
const NAV_LAYOUTS = [
  { name: 'desktop three-column', viewport: { width: 1440, height: 720 }, columns: 3 },
  { name: 'narrow two-column', viewport: { width: 900, height: 800 }, columns: 2 },
  { name: 'mobile single-column', viewport: { width: 480, height: 800 }, columns: 1 }
];

const NAV_TARGETS = [
  { id: 'project', label: 'Project' },
  { id: 'source', label: 'Source' },
  { id: 'graph', label: 'Graph' },
  { id: 'publication', label: 'Publication' },
  { id: 'problems', label: 'Problems' },
  { id: 'preview', label: 'Preview' },
  { id: 'watch', label: 'Watch' }
];

for (const layout of NAV_LAYOUTS) {
  test(`nav currency follows the jump target in the ${layout.name} layout`, async ({ page }) => {
    await installApi(page);
    await page.setViewportSize(layout.viewport);
    await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
    await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toBeVisible();
    // Every pane must be present, Graph and Publication included, or the
    // scenario does not cover the divergence it claims to cover.
    await expect(page.locator('main section')).toHaveCount(NAV_TARGETS.length);

    // Layout precondition: if the breakpoints ever stop laying the panes out
    // differently, this test would run the same scenario three times and stop
    // guarding anything. Assert the column count the scenario is built on.
    expect(
      await page.evaluate(() => {
        const main = document.querySelector('main');
        return main ? getComputedStyle(main).gridTemplateColumns.split(/\s+/).filter(Boolean).length : 0;
      }),
      `${layout.name}: main grid column count`
    ).toBe(layout.columns);

    for (const target of NAV_TARGETS) {
      await navLink(page, target.label).click();
      await waitForJumpToSettle(page);
      const state = await page.evaluate((id) => {
        const ids = Array.from(document.querySelectorAll('.section-nav a'))
          .map(a => (a.getAttribute('href') ?? '').slice(1));
        const present = ids.filter(pid => document.getElementById(pid));
        const el = document.getElementById(id);
        const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
        return {
          current: (document.querySelector('.section-nav a[aria-current="true"]')?.getAttribute('href') ?? '').slice(1) || null,
          order: Array.from(document.querySelectorAll('.section-nav a')).map(a => a.textContent).join(' > '),
          tops: Array.from(document.querySelectorAll('main section')).map(s => `${s.id}:${Math.round(s.getBoundingClientRect().top)}`).join(' '),
          targetTop: el ? Math.round(el.getBoundingClientRect().top) : null,
          targetMargin: el ? parseFloat(getComputedStyle(el).scrollMarginTop) || 0 : null,
          lastPresent: present.length ? present[present.length - 1] : null,
          scrollY: Math.round(window.scrollY),
          maxScroll: Math.round(maxScroll)
        };
      }, target.id);

      // A jump the document cannot satisfy — the target is already as far as
      // the page can scroll — leaves it off the reading line. The contract
      // there is the spy's bottom rule (the last present pane), which the
      // component documents, not the target.
      const parked = state.targetTop !== null && state.targetMargin !== null
        && Math.abs(state.targetTop - state.targetMargin) <= 4;
      const expected = parked ? target.id : state.lastPresent;
      // Soft, so one run reports every pane that diverges rather than
      // stopping at the first — a layout regression usually moves several.
      expect.soft(
        state.current,
        `${layout.name}: jumping to ${target.label} left aria-current on ${state.current}; expected ${expected}. ` +
        `parked=${parked} (targetTop=${state.targetTop}, scroll-margin-top=${state.targetMargin}), ` +
        `scrollY=${state.scrollY}/${state.maxScroll}. nav order: ${state.order}. pane tops: ${state.tops}`
      ).toBe(expected);
    }
  });
}

test('modifier-click keeps the native hash-link behavior', async ({ page }) => {
  await installApi(page);
  const before = page.url();
  // control+click must fall through to the browser (no preventDefault), so
  // the component's hand-off path stays an enhancement, not a replacement.
  await navLink(page, 'Preview').click({ modifiers: ['Control'] });
  expect(page.url()).toBe(before);
  await expect(page.locator('#preview')).not.toHaveClass(/arrived/);
});
