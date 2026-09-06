import { expect, test, type Page } from '@playwright/test';

// Focus writing mode e2e. Same mocked-host approach as safe-editing.spec.ts:
// every endpoint is routed in-page, no Zig host is spawned. The assertions
// cover the surface contract: entry from the Source pane and the command
// palette, the shared-buffer editing round-trip (edit here → Source pane
// shows it, save from here → disk), layout switching with persistence, the
// reading aid rendering, and Escape returning focus to the trigger.

type FocusMockOptions = {
  layout?: string;
  /** Initial disk content served by /api/files/open. */
  disk?: string;
};

async function installApi(page: Page, options: FocusMockOptions = {}) {
  let disk = options.disk ?? '# Home\n';
  let fingerprint = 'a'.repeat(64);

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
      body: JSON.stringify({ status: 'unchanged', fingerprint: body.fingerprint ?? fingerprint, read_only: false })
    });
  });
  await page.route('**/api/files/open', async route => {
    const { path } = route.request().postDataJSON() as { path: string };
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'opened', path, content: disk, fingerprint, read_only: false })
    });
  });
  let saveCount = 0;
  await page.route('**/api/files/save', async route => {
    const body = route.request().postDataJSON() as { path: string; content: string };
    disk = body.content;
    fingerprint = 'c'.repeat(64);
    saveCount += 1;
    await route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: 'saved', path: body.path, content: disk, fingerprint, read_only: false })
    });
  });
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
  // Watch daemon endpoints answer 404 (pre-#938 host shape) like the other
  // suites, so the shell's honest unsupported path runs everywhere.
  await page.route('**/api/watch/state', route => route.fulfill({
    status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
  }));
  await page.route(/\/api\/watch\/events/, route => route.fulfill({
    status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
  }));
  for (const endpoint of ['start', 'stop']) {
    await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({
      status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
    }));
  }
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
  let rebuildCount = 0;
  await page.route('**/api/preview/rebuild', route => {
    rebuildCount += 1;
    return route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        phase: 'success', generation: rebuildCount, exit_code: 0, used_stderr_fallback: false,
        message: 'Preview is current from a successful Boris incremental build.',
        preview_url: 'https://preview.invalid/?token=test'
      })
    });
  });
  await page.route('https://preview.invalid/**', route => route.fulfill({ contentType: 'text/html', body: '<h1>Compiler output</h1>' }));

  if (options.layout) {
    await page.addInitScript((layout: string) => {
      localStorage.setItem('boris-editor-focus-layout', layout);
    }, options.layout);
  }
  await page.goto('/#token=test-session-token');
  return { saveCountRef: () => saveCount, rebuildCountRef: () => rebuildCount };
}

async function openFileAndEnterFocus(page: Page, expected = '# Home\n') {
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue(expected);
  await page.getByRole('button', { name: 'Focus', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Focus writing mode' })).toBeVisible();
  return page.getByRole('textbox', { name: /Focus writing surface for content\/index\.md/ });
}

test('focus mode opens from the Source pane with the shared buffer', async ({ page }) => {
  await installApi(page);
  const editor = await openFileAndEnterFocus(page);
  await expect(editor).toHaveValue('# Home\n');
  await expect(editor).toBeFocused();

  // Chrome and surfaces are present.
  await expect(page.getByRole('heading', { name: 'Focus', level: 2 })).toBeVisible();
  for (const layout of ['Write', 'Split', 'Preview']) {
    await expect(page.getByRole('radio', { name: layout })).toBeChecked({ checked: layout === 'Write' });
  }

  // Editing writes through to the shared buffer: the workspace Source pane
  // (behind the overlay) holds the same draft.
  await editor.fill('# Home\n\nA fresh paragraph.\n');
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await expect(focus.getByRole('status', { name: 'Editing status' })).toContainText('Unsaved changes in content/index.md.');
  // The workspace pane mirrors the same buffer state.
  await expect(page.getByRole('region', { name: 'Source' }).getByRole('status', { name: 'Editing status' })).toContainText('Unsaved changes in content/index.md.');
});

test('editing in focus mode and saving persists to disk and updates the workspace', async ({ page }) => {
  const { saveCountRef } = await installApi(page);
  const editor = await openFileAndEnterFocus(page);
  await editor.fill('# Home\n\nWritten in focus mode.\n');
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  const saveRequest = page.waitForRequest('**/api/files/save');
  await focus.getByRole('button', { name: 'Save file', exact: true }).click();
  expect((await saveRequest).postDataJSON()).toMatchObject({
    path: 'content/index.md',
    content: '# Home\n\nWritten in focus mode.\n'
  });
  expect(saveCountRef()).toBe(1);
  await expect(focus.getByRole('status', { name: 'Editing status' })).toContainText('Saved content/index.md.');
  await expect(focus.getByText('Saved on disk', { exact: true })).toBeVisible();

  // Exiting lands back in the workspace with the saved content in the Source
  // pane's textarea (same buffer).
  await page.getByRole('button', { name: 'Exit focus', exact: true }).click();
  await expect(page.getByRole('dialog', { name: 'Focus writing mode' })).toBeHidden();
  await expect(page.getByRole('textbox', { name: 'Source for content/index.md' })).toHaveValue('# Home\n\nWritten in focus mode.\n');
});

test('Escape exits focus mode and returns focus to the triggering button', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  const trigger = page.getByRole('button', { name: 'Focus', exact: true });
  await trigger.click();
  await expect(page.getByRole('dialog', { name: 'Focus writing mode' })).toBeVisible();
  await page.keyboard.press('Escape');
  await expect(page.getByRole('dialog', { name: 'Focus writing mode' })).toBeHidden();
  await expect(trigger).toBeFocused();
});

test('layout switching updates the surface and persists across reloads', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);

  await page.getByRole('radio', { name: 'Preview' }).check();
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await expect(focus.getByRole('textbox', { name: /Focus writing surface/ })).toHaveCount(0);
  await expect(focus.getByRole('document', { name: 'Reading preview of the open buffer' })).toBeVisible();

  await page.getByRole('radio', { name: 'Split' }).check();
  await expect(focus.getByRole('textbox', { name: /Focus writing surface/ })).toBeVisible();
  await expect(focus.getByRole('document', { name: 'Reading preview of the open buffer' })).toBeVisible();
  await expect(page.getByRole('radio', { name: 'Split' })).toBeChecked();

  await page.getByRole('button', { name: 'Exit focus', exact: true }).click();
  await page.waitForTimeout(50);
  await page.reload();
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('button', { name: 'Focus', exact: true }).click();
  await expect(page.getByRole('radio', { name: 'Split' })).toBeChecked();
  await expect(page.getByRole('document', { name: 'Reading preview of the open buffer' })).toBeVisible();
});

test('the reading aid renders the bounded Markdown subset with live edits', async ({ page }) => {
  await installApi(page);
  const editor = await openFileAndEnterFocus(page);
  await page.getByRole('radio', { name: 'Split' }).check();
  const reading = page.getByRole('dialog', { name: 'Focus writing mode' }).getByRole('document', { name: 'Reading preview of the open buffer' });

  await editor.fill('# Draft\n\nHello **world** with `code`.\n');
  await expect(reading.getByRole('heading', { name: 'Draft', level: 1 })).toBeVisible();
  await expect(reading.getByRole('strong')).toContainText('world');
  await expect(reading.getByRole('code')).toContainText('code');

  // Wiki links render honestly as non-navigable spans (no route graph here).
  await editor.fill('# Draft\n\nSee [[guides/intro|the guide]].\n');
  await expect(reading.locator('.focus-wikilink')).toHaveText('the guide');

  // Script injection is escaped everywhere, including code blocks.
  await editor.fill('# T\n\n```html\n<script>alert(1)</script>\n```\n');
  await expect(reading.locator('pre code')).toContainText('<script>alert(1)</script>');
  await expect(reading.locator('script')).toHaveCount(0);
});

test('the command palette enters and exits focus mode', async ({ page }) => {
  await installApi(page);
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.keyboard.press('Control+k');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  await expect(palette).toBeVisible();
  await palette.getByRole('combobox').fill('focus');
  // Overlay closed: Enter is enabled, Exit is rendered but disabled.
  await expect(palette.getByRole('option', { name: /Enter focus writing mode/ })).toHaveAttribute('aria-disabled', 'false');
  await expect(palette.getByRole('option', { name: /Exit focus writing mode/ })).toHaveAttribute('aria-disabled', 'true');
  await palette.getByRole('option', { name: /Enter focus writing mode/ }).click();
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await expect(focus).toBeVisible();

  // Overlay open: the palette opens above it (the native dialog wins the
  // top layer) and the gating flips.
  await page.keyboard.press('Control+k');
  await expect(palette).toBeVisible();
  await palette.getByRole('combobox').fill('focus');
  await expect(palette.getByRole('option', { name: /Enter focus writing mode/ })).toHaveAttribute('aria-disabled', 'true');
  await expect(palette.getByRole('option', { name: /Exit focus writing mode/ })).toHaveAttribute('aria-disabled', 'false');
  await palette.getByRole('option', { name: /Exit focus writing mode/ }).click();
  await expect(focus).toBeHidden();
  // Palette entry has no durable trigger (the option unmounts), so the
  // keyboard returns to the workspace editor instead of stranding on <body>.
  await expect(page.locator('#source-editor')).toBeFocused();
});

test('rebuild preview works from focus mode', async ({ page }) => {
  const { rebuildCountRef } = await installApi(page);
  await openFileAndEnterFocus(page);
  const rebuildRequest = page.waitForRequest('**/api/preview/rebuild');
  await page.getByRole('dialog', { name: 'Focus writing mode' }).getByRole('button', { name: 'Rebuild preview', exact: true }).click();
  await rebuildRequest;
  await expect
    .poll(() => rebuildCountRef())
    .toBe(1);
});

test('typography controls restyle the surface and persist across reloads', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  const surface = page.locator('.focus-surface');
  const details = focus.locator('details.focus-type');

  // Defaults: M size, medium measure, serif face.
  await expect(surface).toHaveAttribute('data-size', 'm');
  await expect(surface).toHaveAttribute('data-measure', 'medium');
  await expect(surface).toHaveAttribute('data-face', 'serif');

  // The controls live in the disclosure; open it to reach them.
  await page.locator('details.focus-type:not(.focus-aids) summary').click();
  await expect(focus.getByRole('radio', { name: 'M', exact: true })).toBeChecked();

  // The computed style of the writing surface follows the choice.
  const fontBefore = await focus.getByRole('textbox', { name: /Focus writing surface/ }).evaluate(
    node => getComputedStyle(node).fontFamily
  );
  expect(fontBefore).toContain('Charter');
  const sizeBefore = await focus.getByRole('textbox', { name: /Focus writing surface/ }).evaluate(
    node => getComputedStyle(node).fontSize
  );

  await focus.getByRole('radio', { name: 'XL', exact: true }).check();
  await focus.getByRole('radio', { name: 'Narrow' }).check();
  await focus.getByRole('radio', { name: 'Sans' }).check();

  await expect(surface).toHaveAttribute('data-size', 'xl');
  await expect(surface).toHaveAttribute('data-measure', 'narrow');
  await expect(surface).toHaveAttribute('data-face', 'sans');
  const style = await focus.getByRole('textbox', { name: /Focus writing surface/ }).evaluate(
    node => { const s = getComputedStyle(node); return { family: s.fontFamily, size: s.fontSize }; }
  );
  expect(style.family).toContain('Inter');
  expect(parseFloat(style.size)).toBeGreaterThan(parseFloat(sizeBefore));

  // Persistence: reload, reopen, and the choices are still in place.
  await page.reload();
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('button', { name: 'Focus', exact: true }).click();
  const surfaceAfter = page.locator('.focus-surface');
  await expect(surfaceAfter).toHaveAttribute('data-size', 'xl');
  await expect(surfaceAfter).toHaveAttribute('data-measure', 'narrow');
  await expect(surfaceAfter).toHaveAttribute('data-face', 'sans');
});

test('corrupted typography storage falls back to defaults field-by-field', async ({ page }) => {
  await installApi(page);
  await page.addInitScript(() => {
    localStorage.setItem('boris-editor-focus-type', JSON.stringify({ size: 'giant', measure: 42, face: 'wingdings' }));
  });
  await openFileAndEnterFocus(page);
  const surface = page.locator('.focus-surface');
  await expect(surface).toHaveAttribute('data-size', 'm');
  await expect(surface).toHaveAttribute('data-measure', 'medium');
  await expect(surface).toHaveAttribute('data-face', 'serif');
});

test('typography radios are scoped to the focus overlay, not the workspace', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.locator('details.focus-type:not(.focus-aids) summary').click();
  // The workspace has no 'S' radio; only the focus overlay's typography
  // group does — the strict-mode locator proves the scoping.
  await expect(page.getByRole('radio', { name: 'S', exact: true })).toHaveCount(1);
  await expect(page.getByRole('radio', { name: 'XL', exact: true })).toHaveCount(1);
});

test('typewriter scrolling keeps the caret line centered while typing', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.locator('details.focus-aids summary').click();
  await focus.getByRole('radio', { name: 'Typewriter scrolling on' }).check();

  const editor = focus.getByRole('textbox', { name: /Focus writing surface/ });
  const manyLines = Array.from({ length: 60 }, (_, i) => `Paragraph ${i + 1} of sixty.`).join('\n\n');
  await editor.fill(manyLines);
  await editor.press('Control+End');
  await editor.pressSequentially(' and more typing here');

  // The caret sits near the vertical center of the visible box, within a
  // line-height of tolerance. The caret rect comes from the mirror element
  // (a textarea exposes no text node to build a Range from); both fill the
  // same shell, so their boxes share an origin. The caret is placed at a
  // mid-document blank line first: at the document end, centering is
  // physically impossible (scrollTop clamps at max) and the assertion would
  // compare against an unreachable state.
  await editor.press('Control+Home');
  const contentLen = await editor.evaluate(node => node.value.length);
  await editor.evaluate((node, len) => {
    (node as HTMLTextAreaElement).setSelectionRange(Math.floor(len / 2), Math.floor(len / 2));
  }, contentLen);
  await editor.pressSequentially(' typing in the middle');

  const scrollTop = await editor.evaluate(node => node.scrollTop);
  expect(scrollTop).toBeGreaterThan(0);

  const drift = await page.evaluate(() => {
    const node = document.querySelector('.focus-editor') as HTMLTextAreaElement;
    const mirror = document.querySelector('.focus-mirror') as HTMLElement;
    const mirrorTop = mirror.getBoundingClientRect().top;
    const range = document.createRange();
    const text = mirror.firstChild;
    const caret = node.selectionStart;
    // Widen by one character so a mid-line collapsed caret still yields a
    // rect (same fallback the component uses).
    range.setStart(text!, Math.max(0, caret - 1));
    range.setEnd(text!, caret);
    const rects = range.getClientRects();
    const last = rects[rects.length - 1];
    const caretCenter = last ? (last.top + last.bottom) / 2 - mirrorTop : 0;
    const viewCenter = node.scrollTop + node.clientHeight / 2;
    return Math.abs(caretCenter - viewCenter);
  });
  expect(drift).toBeLessThan(40);
});

test('paragraph dimming veils the surface and follows the caret paragraph', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.locator('details.focus-type summary').nth(1).click();
  await focus.getByRole('radio', { name: 'Paragraph dimming on' }).check();

  const shell = page.locator('.focus-editor-shell');
  const underlay = page.locator('.zen-underlay');
  const editor = focus.getByRole('textbox', { name: /Focus writing surface/ });

  await expect(underlay).toBeVisible();
  await expect(shell).toHaveCSS('--zen-underlay', '1');

  // The mask keeps a bright window over the caret's paragraph. mask-image is
  // expressed as a hard-stop gradient (polygon() is not a valid mask-image
  // value), so the assertion looks for gradient stops, not polygons.
  await editor.fill('First paragraph stands alone.\n\nSecond paragraph follows.\n\nThird one too.');
  const masked = await underlay.evaluate(node => getComputedStyle(node).webkitMaskImage || getComputedStyle(node).maskImage);
  expect(masked).toContain('linear-gradient');
  // Computed styles serialize `transparent` as rgba(0, 0, 0, 0): the bright
  // window over the caret's paragraph.
  expect(masked).toContain('rgba(0, 0, 0, 0)');

  // The veil announces itself in the accessible name of the surface.
  await expect(editor).toHaveAccessibleName(/paragraph focus dimming on/);

  // Turning it off clears the veil and the mask.
  await focus.getByRole('radio', { name: 'Paragraph dimming off' }).check();
  await expect(shell).toHaveCSS('--zen-underlay', '0');
  const cleared = await underlay.evaluate(node => getComputedStyle(node).webkitMaskImage || getComputedStyle(node).maskImage);
  expect(cleared).not.toContain('linear-gradient');
  expect(cleared).not.toContain('rgba(0, 0, 0, 0)');
});

test('arrows do nothing harmful when focus mode opens with no file', async ({ page }) => {
  // No file is opened, so the overlay renders the honest empty state and
  // there is no writing surface. The arrow rescue must not throw or swallow
  // the keys without a target (regression: non-null assertion on a missing
  // textarea).
  const pageErrors: string[] = [];
  page.on('pageerror', err => pageErrors.push(err.message));
  await installApi(page);
  await page.getByRole('button', { name: 'Focus', exact: true }).click();
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await expect(focus).toBeVisible();
  await expect(page.locator('.focus-editor')).toHaveCount(0);
  await focus.click({ position: { x: 20, y: 20 } });
  await page.keyboard.press('ArrowDown');
  await page.keyboard.press('ArrowLeft');
  expect(pageErrors).toEqual([]);
});

test('background workspace is inert while the overlay is open', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);
  const workspace = page.locator('#workspace');
  await expect(workspace).toHaveAttribute('inert', '');
  await page.getByRole('button', { name: 'Exit focus', exact: true }).click();
  await expect(page.locator('#workspace')).not.toHaveAttribute('inert', '');
});

test('reading aid renders frontmatter as a collapsed muted band, not body text', async ({ page }) => {
  await installApi(page, {
    disk: '---\ntitle: Front matter demo\ndraft: false\n---\n\n# Real body\n\nProse lives here.\n'
  });
  await openFileAndEnterFocus(page, '---\ntitle: Front matter demo\ndraft: false\n---\n\n# Real body\n\nProse lives here.\n');
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.getByRole('radio', { name: 'Preview', exact: true }).check();
  const reading = page.locator('.focus-reading');
  const band = reading.locator('details.focus-frontmatter');
  await expect(band).toBeVisible();
  await expect(band.locator('summary')).toHaveText('frontmatter · 2 keys');
  // The YAML lives inside the collapsed band (escaped text), and the body
  // renders — but no paragraph anywhere carries the frontmatter values.
  await expect(band.locator('code')).toContainText('title: Front matter demo');
  await expect(reading.locator('h1')).toHaveText('Real body');
  await expect(reading.locator('p', { hasText: 'Front matter demo' })).toHaveCount(0);
  await expect(reading.locator('p', { hasText: 'draft: false' })).toHaveCount(0);
});

test('reading aid never produces executable content (escape + anchor policy)', async ({ page }) => {
  await installApi(page, {
    disk: '# Home\n\n<img src=x onerror="window.__pwned=1"> [x](javascript:alert(1)) [ok](https://example.com/a)\n'
  });
  await openFileAndEnterFocus(page, '# Home\n\n<img src=x onerror="window.__pwned=1"> [x](javascript:alert(1)) [ok](https://example.com/a)\n');
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.getByRole('radio', { name: 'Preview', exact: true }).check();
  const reading = page.locator('.focus-reading');
  await expect(reading.getByRole('link', { name: 'ok' })).toHaveAttribute('href', 'https://example.com/a');
  const audit = await reading.evaluate((node) => {
    const anchors = [...node.querySelectorAll('a')];
    return {
      pwned: (window as unknown as { __pwned?: number }).__pwned ?? 0,
      anchors: anchors.length,
      scriptNodes: node.querySelectorAll('script, iframe, img').length,
      badHrefs: anchors.filter(a => /\s*(javascript|data|vbscript):/i.test(a.getAttribute('href') ?? '')).length,
      text: node.textContent ?? ''
    };
  });
  expect(audit.pwned).toBe(0);
  expect(audit.scriptNodes).toBe(0);
  expect(audit.badHrefs).toBe(0);
  // Exactly one anchor (the https target); the blocked javascript: link
  // renders as its bare label. The img tag surfaces as fully escaped inert
  // text — present in textContent, never as an element, never executed.
  expect(audit.anchors).toBe(1);
  expect(audit.text).toContain('<img src=x onerror="window.__pwned=1">');
});

test('spaced thematic breaks render as rules, not list items', async ({ page }) => {
  await installApi(page, {
    disk: '# Home\n\n* * *\n\n- - -\n\nAfter the rules.\n'
  });
  await openFileAndEnterFocus(page, '# Home\n\n* * *\n\n- - -\n\nAfter the rules.\n');
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.getByRole('radio', { name: 'Preview', exact: true }).check();
  const reading = page.locator('.focus-reading');
  await expect(reading.locator('hr')).toHaveCount(2);
  await expect(reading.locator('ul li')).toHaveCount(0);
});

test('writing aids persist across reloads', async ({ page }) => {
  await installApi(page);
  await openFileAndEnterFocus(page);
  const focus = page.getByRole('dialog', { name: 'Focus writing mode' });
  await focus.locator('details.focus-type summary').nth(1).click();
  await focus.getByRole('radio', { name: 'Typewriter scrolling on' }).check();
  await focus.getByRole('radio', { name: 'Paragraph dimming on' }).check();

  await page.reload();
  await page.getByRole('button', { name: 'content/index.md', exact: true }).click();
  await page.getByRole('button', { name: 'Focus', exact: true }).click();
  const reopened = page.getByRole('dialog', { name: 'Focus writing mode' });
  await reopened.locator('details.focus-type summary').nth(1).click();
  await expect(reopened.getByRole('radio', { name: 'Typewriter scrolling on' })).toBeChecked();
  await expect(reopened.getByRole('radio', { name: 'Paragraph dimming on' })).toBeChecked();
});
