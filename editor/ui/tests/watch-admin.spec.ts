import { expect, test, type Page } from '@playwright/test';

// Watch daemon admin surface e2e (#938 backend, watch-admin UI slice).
// Uses the same mocked-host approach as safe-editing.spec.ts: every endpoint
// is routed in-page, no Zig host is spawned. The mock daemon is a small
// stateful stand-in for the host's spool-file supervision: strictly
// increasing seq across restarts, `gap: true` + `oldest_seq` on eviction,
// and compiler --watch-json NDJSON objects passed through verbatim
// (docs/contracts/watch-mode.md §8).

type WatchDaemonState = {
  supported: boolean;
  state: 'idle' | 'running' | 'success' | 'failed' | 'stale';
  seq: number;
  cycle: number;
  events_count: number;
  oldest_seq: number | null;
  dropped_lines: number;
  last_event: Record<string, unknown> | null;
  compiler_id: string | null;
  hello_schema: string | null;
  last_error: string | null;
};

type WatchMode = 'supported' | 'missing' | 'refused';

function mockWatchDaemon() {
  let running = false;
  let seq = 0;
  let cycle = 0;
  let stateName: WatchDaemonState['state'] = 'idle';
  let lastError: string | null = null;
  let ring: Array<{ seq: number; event: Record<string, unknown> }> = [];
  const push = (event: Record<string, unknown>) => {
    seq += 1;
    ring.push({ seq, event });
  };
  return {
    start(): 'started' | 'already-running' {
      if (running) return 'already-running';
      running = true;
      stateName = 'running';
      lastError = null;
      push({ event: 'hello', watch_events_schema: 1, compiler: 'boris/0.9.0' });
      push({ event: 'build-started', phase: 'initial', mode: 'html', targets: ['default'] });
      push({ event: 'watcher-started', mode: 'html', targets: ['default'] });
      return 'started';
    },
    stop(): 'stopped' | 'not-running' {
      if (!running) return 'not-running';
      running = false;
      stateName = 'idle';
      push({ event: 'watch-stopped', reason: 'signal' });
      return 'stopped';
    },
    succeed(pagesWritten: number, durationMs: number, changed: string[]) {
      cycle += 1;
      stateName = 'success';
      push({
        event: 'build-succeeded', phase: 'rebuild', mode: 'html', targets: ['default'],
        changed, pages_written: pagesWritten, duration_ms: durationMs
      });
    },
    fail(errors: number, message: string, sourcePath: string, recoverable = true) {
      cycle += 1;
      stateName = 'failed';
      lastError = `${sourcePath}: ${message}`;
      push({
        event: 'build-failed', phase: 'rebuild', mode: 'html', targets: ['default'],
        errors,
        diagnostics: [{
          severity: 'error', code: 'EFRONTMATTER', message, remediation: 'Fix the frontmatter.',
          sourcePath, line: 1, column: 1, id: null
        }],
        recoverable, duration_ms: 21
      });
    },
    evictTo(firstSeq: number) {
      ring = ring.filter(entry => entry.seq >= firstSeq);
    },
    isActive(): boolean {
      return stateName !== 'idle';
    },
    state(): WatchDaemonState {
      return {
        supported: true, state: stateName, seq, cycle,
        events_count: ring.length,
        oldest_seq: ring.length ? ring[0].seq : null,
        dropped_lines: 0,
        last_event: ring.length ? ring[ring.length - 1].event : null,
        compiler_id: 'boris/0.9.0',
        hello_schema: 'boris-watch-events-1',
        last_error: lastError
      };
    },
    events(after: number) {
      const events = ring.filter(entry => entry.seq > after);
      const gap = after >= 0 && ring.length > 0 && ring[0].seq > after + 1;
      return {
        supported: true, seq,
        oldest_seq: ring.length ? ring[0].seq : null,
        gap, events
      };
    }
  };
}

type WatchApiOptions = {
  watchMode?: WatchMode;
  startRunning?: boolean;
  rebuildResponse?: { status: number; body: Record<string, unknown> };
};

async function installWatchApi(page: Page, options: WatchApiOptions = {}): Promise<ReturnType<typeof mockWatchDaemon>> {
  const watchMode = options.watchMode ?? 'supported';
  const daemon = mockWatchDaemon();
  if (options.startRunning) daemon.start();
  const refuseBody = JSON.stringify({ error: 'watch_unsupported' });

  await page.route('**/api/health', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      status: 'ok', editor_id: 'boris-editor/0.1.0',
      project: { content: true, default_layout: true, publication_profile: true, input_mode: 'markdown' }
    })
  }));
  await page.route('**/api/version', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({ compiler_id: 'boris/0.9.0', supported: { validate_watch: true, watch_json: watchMode === 'supported' } })
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
  await page.route('**/api/authoring', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      frontmatter_schema: { title: 'Boris frontmatter grammar (schema v1)', properties: {} },
      completion: null, completion_status: 'build_required'
    })
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
      preview_url: 'https://preview.invalid/?token=test',
      watch_active: watchMode === 'supported' && daemon.isActive()
    })
  }));
  await page.route('**/api/preview/rebuild', route => {
    if (options.rebuildResponse) {
      return route.fulfill({
        status: options.rebuildResponse.status,
        contentType: 'application/json',
        body: JSON.stringify(options.rebuildResponse.body)
      });
    }
    return route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({
        phase: 'success', generation: 1, exit_code: 0, used_stderr_fallback: false,
        message: 'Preview is current from a successful Boris incremental build.',
        preview_url: 'https://preview.invalid/?token=test'
      })
    });
  });
  await page.route('**/api/commands/run', route => route.fulfill({
    contentType: 'application/json',
    body: JSON.stringify({
      mode: 'validate', exit_code: 0, failure_class: 'success', compiler_id: 'boris/0.9.0',
      report_version: null, used_stderr_fallback: false, problems: [], findings: [], impact: []
    })
  }));

  // The watch endpoints, per mode: 'supported' wires the stateful daemon,
  // 'missing' mirrors a pre-#938 host (404 everywhere), 'refused' mirrors a
  // host whose compiler refuses the --watch-json handshake (state says
  // supported:false, start answers 409 watch_unsupported).
  if (watchMode === 'supported') {
    await page.route('**/api/watch/state', route => route.fulfill({
      contentType: 'application/json', body: JSON.stringify(daemon.state())
    }));
    await page.route(/\/api\/watch\/events/, route => {
      const after = Number(new URL(route.request().url()).searchParams.get('after') ?? '-1');
      return route.fulfill({ contentType: 'application/json', body: JSON.stringify(daemon.events(after)) });
    });
    await page.route('**/api/watch/start', route => route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: daemon.start(), state: daemon.state() })
    }));
    await page.route('**/api/watch/stop', route => route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ status: daemon.stop(), state: daemon.state() })
    }));
  } else if (watchMode === 'refused') {
    await page.route('**/api/watch/state', route => route.fulfill({
      contentType: 'application/json',
      body: JSON.stringify({ supported: false, state: 'idle', seq: 0, cycle: 0 })
    }));
    await page.route(/\/api\/watch\/events/, route => route.fulfill({
      status: 409, contentType: 'application/json', body: refuseBody
    }));
    await page.route('**/api/watch/start', route => route.fulfill({
      status: 409, contentType: 'application/json', body: refuseBody
    }));
    await page.route('**/api/watch/stop', route => route.fulfill({
      status: 409, contentType: 'application/json', body: refuseBody
    }));
  } else {
    for (const endpoint of ['state', 'start', 'stop']) {
      await page.route(`**/api/watch/${endpoint}`, route => route.fulfill({
        status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
      }));
    }
    await page.route(/\/api\/watch\/events/, route => route.fulfill({
      status: 404, contentType: 'application/json', body: JSON.stringify({ error: 'not_found' })
    }));
  }

  await page.goto('/#token=test-session-token');
  return daemon;
}

test('supported flow: start, build-succeeded and build-failed events, then stop', async ({ page }) => {
  const daemon = await installWatchApi(page);
  const stateLine = page.getByRole('status', { name: 'Watch daemon state' });
  await expect(stateLine).toHaveText('Watch daemon is idle. Start it to build on change.');
  const start = page.getByRole('button', { name: 'Start watch daemon', exact: true });
  const stop = page.getByRole('button', { name: 'Stop watch daemon', exact: true });
  await expect(start).toBeEnabled();
  await expect(stop).toBeDisabled();

  const startRequest = page.waitForRequest('**/api/watch/start');
  await start.click();
  expect((await startRequest).method()).toBe('POST');
  await expect(page.getByRole('status', { name: 'Watch status' })).toContainText('Watch daemon started.');
  await expect(stateLine).toHaveText('Watch daemon is running.');
  await expect(start).toBeDisabled();
  await expect(stop).toBeEnabled();
  const feed = page.getByRole('list', { name: 'Watch event feed' });
  await expect(feed).toContainText('Handshake: boris/0.9.0 speaks watch events schema 1.');

  daemon.succeed(3, 45, ['index.md']);
  await expect(feed).toContainText('Build succeeded: 3 pages written in 45 ms. Changed: index.md.');
  await expect(stateLine).toHaveText('Watch build succeeded (cycle 1).');
  await expect(page.getByText('Compiler: boris/0.9.0 · Cycle: 1', { exact: true })).toBeVisible();

  daemon.fail(2, 'Unknown key.', 'index.md');
  await expect(feed).toContainText('Build failed: 2 errors — EFRONTMATTER index.md:1 Unknown key.');
  await expect(stateLine).toHaveText('Watch build failed (cycle 2).');
  await expect(page.getByText('Last daemon error: index.md: Unknown key.')).toBeVisible();

  const stopRequest = page.waitForRequest('**/api/watch/stop');
  await stop.click();
  expect((await stopRequest).method()).toBe('POST');
  await expect(page.getByRole('status', { name: 'Watch status' })).toContainText('Watch daemon stopped.');
  await expect(stateLine).toHaveText('Watch daemon is idle. Start it to build on change.');
  await expect(start).toBeEnabled();
  await expect(stop).toBeDisabled();
  // The feed keeps its history, newest first, with the shutdown line on top:
  // hello(1) build-started(2) watcher-started(3) succeeded(4) failed(5) stopped(6).
  await expect(feed).toContainText('Watch stopped (signal).');
  const seqs = await feed.locator('.watch-event-seq').allTextContents();
  expect(seqs[0]).toBe('#6');
});

test('unsupported 404 host names the honest message and keeps controls out', async ({ page }) => {
  await installWatchApi(page, { watchMode: 'missing' });
  const stateLine = page.getByRole('status', { name: 'Watch daemon state' });
  await expect(stateLine).toHaveText('This Boris build does not support the watch daemon.');
  await expect(page.getByRole('button', { name: 'Start watch daemon' })).toHaveCount(0);
  await expect(page.getByRole('button', { name: 'Stop watch daemon' })).toHaveCount(0);
  // No error spin: the message stays stable across the poll cadence.
  await page.waitForTimeout(1100);
  await expect(stateLine).toHaveText('This Boris build does not support the watch daemon.');
});

test('a compiler that refuses --watch-json is named unsupported, not errored', async ({ page }) => {
  await installWatchApi(page, { watchMode: 'refused' });
  const stateLine = page.getByRole('status', { name: 'Watch daemon state' });
  await expect(stateLine).toHaveText('This Boris build does not support the watch daemon.');
  await expect(page.getByRole('button', { name: 'Start watch daemon' })).toHaveCount(0);
});

test('ring eviction resyncs the feed and labels the boundary honestly', async ({ page }) => {
  const daemon = await installWatchApi(page);
  // Preload a daemon that already built once: hello(1), build-started(2),
  // watcher-started(3), succeeded(4) — the first sync window covers #1..#4.
  daemon.start();
  daemon.succeed(2, 30, ['index.md']);
  const feed = page.getByRole('list', { name: 'Watch event feed' });
  await expect(feed).toContainText('#4');
  await expect(feed).toContainText('Build succeeded: 2 pages written in 30 ms. Changed: index.md.');

  // Produce three more rebuild events (seq 5–7) and evict down to #6: the
  // cursor at #4 can no longer be satisfied, so the host answers gap:true.
  // All mutations happen in one synchronous turn so no poll interleaves.
  daemon.succeed(1, 12, ['about.md']);
  daemon.succeed(1, 15, ['contact.md']);
  daemon.succeed(1, 18, ['blog.md']);
  daemon.evictTo(6);
  await expect(feed).toContainText('Older events were evicted from the daemon ring; the feed resumes at event #6.', { timeout: 8000 });
  await expect(feed).toContainText('#7');
  await expect(feed).not.toContainText('#4');
  const seqs = await feed.locator('.watch-event-seq').allTextContents();
  expect(seqs).toEqual(['#7', '#6']);
  // The resync never replays an event twice.
  expect(seqs.filter(entry => entry === '#6')).toHaveLength(1);
});

test('a rebuild refused by the active daemon points at the Watch pane and recovers after stop', async ({ page }) => {
  const daemon = await installWatchApi(page, {
    startRunning: true,
    rebuildResponse: { status: 409, body: { error: 'watch_daemon_active' } }
  });
  const stateLine = page.getByRole('status', { name: 'Watch daemon state' });
  await expect(stateLine).toHaveText('Watch daemon is running.');
  // The additive watch_active flag from /api/preview/state drives the note.
  const note = page.getByRole('status', { name: 'Watch daemon active note' });
  await expect(note).toContainText('The watch daemon is active');
  await expect(note).toContainText('Watch pane');

  await page.getByRole('button', { name: 'Rebuild preview', exact: true }).click();
  const previewState = page.locator('.preview-state');
  await expect(previewState).toContainText('refused');
  await expect(previewState).toContainText('Watch pane');
  // The optimistic running phase is undone: the preview is honestly idle again.
  await expect(previewState).toContainText('idle:');
  await expect(page.getByRole('button', { name: 'Rebuild preview', exact: true })).toBeEnabled();

  await page.getByRole('button', { name: 'Stop watch daemon', exact: true }).click();
  await expect(stateLine).toHaveText('Watch daemon is idle. Start it to build on change.');
  await expect(note).toBeHidden();
  void daemon;
});

test('watch controls are visibly named and reachable by keyboard and palette', async ({ page }) => {
  const daemon = await installWatchApi(page);
  const start = page.getByRole('button', { name: 'Start watch daemon', exact: true });
  const stop = page.getByRole('button', { name: 'Stop watch daemon', exact: true });
  await expect(start).toHaveText('Start watch daemon');
  await expect(stop).toHaveText('Stop watch daemon');

  // Palette: the three watch entries with honest enabled states while idle.
  await page.keyboard.press('Control+K');
  const palette = page.getByRole('dialog', { name: 'Commands' });
  await palette.getByRole('combobox', { name: 'Filter commands' }).fill('watch');
  const options = palette.locator('[role="option"]');
  await expect(options.filter({ hasText: 'Start watch daemon' })).toHaveAttribute('aria-disabled', 'false');
  await expect(options.filter({ hasText: 'Stop watch daemon' })).toHaveAttribute('aria-disabled', 'true');
  await expect(options.filter({ hasText: 'Go to watch' })).toHaveAttribute('aria-disabled', 'false');
  await palette.getByRole('combobox', { name: 'Filter commands' }).press('Escape');
  await expect(palette).toBeHidden();

  // Keyboard start: focus the visible button and press Enter.
  const startRequest = page.waitForRequest('**/api/watch/start');
  await start.focus();
  await page.keyboard.press('Enter');
  expect((await startRequest).method()).toBe('POST');
  await expect(page.getByRole('status', { name: 'Watch daemon state' })).toHaveText('Watch daemon is running.');

  // Palette "Go to watch" moves focus to the pane itself.
  await page.keyboard.press('Control+K');
  const paletteAgain = page.getByRole('dialog', { name: 'Commands' });
  await paletteAgain.getByRole('combobox', { name: 'Filter commands' }).fill('go to watch');
  await paletteAgain.getByRole('combobox', { name: 'Filter commands' }).press('Enter');
  await expect(paletteAgain).toBeHidden();
  await expect(page.locator('#watch')).toBeFocused();
  void daemon;
});
