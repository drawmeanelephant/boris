// editor/ui/src/lib/state/watch.svelte.ts
// Managed watch daemon state: the /api/watch/state payload, the bounded event
// feed, the seq cursor, and the honest supported/unsupported decision. The
// poller mirrors the validate-state cadence — ~1s while the daemon is active
// or a start/stop is in flight, ~5s otherwise — as a plain setInterval, like
// every other poll in the shell. No SSE, no second pipeline: the compiler's
// --watch-json events arrive through the host's polling endpoints verbatim.
//
// Compatibility path: against a host (or compiler) without the watch admin
// backend the state probe answers non-ok (404) or 409 watch_unsupported. That
// is an honest `supported: false` with disabled controls — never an error
// spin and never a fabricated state.

import { api, elapsedLabel } from '../api';
import type {
  ErrorResponse,
  WatchEventRecord,
  WatchEventsResponse,
  WatchStatePayload,
  WatchStartResponse,
  WatchStopResponse
} from '../types';
import { watchEventSummary, type WatchEventTone } from '../utils';
import { clearWatchRefusal, refreshPreviewState } from './preview.svelte';

export type WatchFeedItem = {
  key: string;
  seq: number | null;
  label: string;
  tone: WatchEventTone | 'boundary';
};

// The feed keeps the newest window of daemon events, newest visible first.
export const watchEventWindow = 50;

export const watch = $state({
  // null until the first /api/watch/state probe answers; false is the honest
  // unsupported verdict for a non-ok/404 host or a refused start.
  supported: null as boolean | null,
  state: null as WatchStatePayload | null,
  status: 'No watch daemon action has run yet.',
  feed: [] as WatchFeedItem[],
  inFlight: false
});

// The daemon is active once it has been started, including the backoff-restart
// window (`stale`) — the dist/ writer seat is the daemon's the whole time.
export function watchDaemonActive(): boolean {
  const name = watch.state?.state;
  return name !== undefined && name !== 'idle';
}

export function watchStartEnabled(): boolean {
  return watch.supported === true && !watch.inFlight && !watchDaemonActive();
}

export function watchStopEnabled(): boolean {
  return watch.supported === true && !watch.inFlight && watchDaemonActive();
}

// Seq cursor: the last event seq this session consumed. The host assigns
// strictly increasing seqs across daemon restarts for the host session, so a
// plain `after=<cursor>` follow never replays an event; eviction surfaces as
// `gap: true` plus `oldest_seq` and resyncs the window with an honest
// boundary label instead of silently skipping.
let cursor: number | null = null;

let stateTimer: ReturnType<typeof setInterval> | undefined;
let tickCount = 0;

// Mirrors startValidateWatch: called once after connect, plain setInterval.
export function startWatchStateWatch(): void {
  if (stateTimer) return;
  void pollWatch(true);
  stateTimer = setInterval(() => void pollWatch(false), 1000);
}

function shouldPollImmediately(): boolean {
  return watch.inFlight || watchDaemonActive();
}

async function pollWatch(force: boolean): Promise<void> {
  tickCount += 1;
  if (!force && !shouldPollImmediately() && tickCount % 5 !== 1) return;
  const result = await api<WatchStatePayload | ErrorResponse>('/api/watch/state');
  if (!result.response.ok) {
    // host_unavailable is a dead host, not an unsupported compiler: the
    // connection line owns that verdict, so keep the last known state.
    if ((result.data as ErrorResponse).error !== 'host_unavailable') markUnsupported();
    return;
  }
  const state = result.data as WatchStatePayload;
  if (state.supported === false) {
    markUnsupported();
    return;
  }
  applyState(state);
  await pollEvents(state);
}

function markUnsupported(): void {
  if (watch.supported === false) return;
  watch.supported = false;
  watch.state = null;
  watch.status = 'This Boris build does not support the watch daemon.';
}

function applyState(state: WatchStatePayload): void {
  const wasActive = watchDaemonActive();
  watch.supported = true;
  watch.state = state;
  const isActive = watchDaemonActive();
  // Keep the Preview pane's refusal note and its `watch_active` flag honest
  // across daemon transitions observed here rather than in the click handlers:
  // a start re-reads the authoritative payload, and a stop also needs that
  // re-read — clearing the refusal flag alone would leave a stale
  // `watch_active: true` keeping the note visible after the daemon stopped.
  if (wasActive && !isActive) {
    clearWatchRefusal();
    void refreshPreviewState();
  }
  if (!wasActive && isActive) void refreshPreviewState();
  // A seq regression means the daemon's ring restarted under this cursor:
  // drop the cursor and resync as a fresh window on the events fetch.
  if (cursor !== null && (state.seq ?? 0) < cursor) cursor = null;
}

async function pollEvents(state: WatchStatePayload): Promise<void> {
  const seq = state.seq ?? 0;
  let after: number;
  if (cursor === null) {
    after = Math.max(-1, seq - watchEventWindow);
  } else {
    after = cursor;
  }
  const result = await api<WatchEventsResponse | ErrorResponse>(`/api/watch/events?after=${after}`);
  if (!result.response.ok) return;
  const payload = result.data as WatchEventsResponse;
  const events = payload.events ?? [];
  const oldestSeq = payload.oldest_seq ?? null;
  // Ring eviction: the host could not return everything after the cursor
  // (`gap: true`), or the oldest retained event sits past the cursor. Resync
  // the window and label the boundary instead of pretending nothing was lost.
  const evicted = cursor !== null && oldestSeq !== null && oldestSeq > cursor + 1;
  if (payload.gap === true || evicted) {
    resyncFeed(events, oldestSeq);
    return;
  }
  appendEvents(events);
}

function appendEvents(events: WatchEventRecord[]): void {
  for (const record of events) {
    if (record.seq <= (cursor ?? -1)) continue;
    const summary = watchEventSummary(record.event);
    watch.feed.unshift({
      key: `event:${record.seq}`,
      seq: record.seq,
      label: summary.label,
      tone: summary.tone
    });
    cursor = record.seq;
  }
  trimFeed();
}

function resyncFeed(events: WatchEventRecord[], oldestSeq: number | null): void {
  watch.feed = [];
  cursor = oldestSeq !== null ? oldestSeq - 1 : -1;
  appendEvents(events);
  if (oldestSeq !== null && oldestSeq > 0) {
    watch.feed.push({
      key: `boundary:${oldestSeq}`,
      seq: null,
      label: `Older events were evicted from the daemon ring; the feed resumes at event #${oldestSeq}.`,
      tone: 'boundary'
    });
  }
  trimFeed();
}

function trimFeed(): void {
  if (watch.feed.length > watchEventWindow) watch.feed.length = watchEventWindow;
}

// Start is explicit and unconfirmed like the other Boris command buttons —
// the host owns the fixed invocation, so the UI has no argv to confirm.
export async function startWatchDaemon(): Promise<void> {
  if (watch.supported !== true || watch.inFlight) return;
  watch.inFlight = true;
  const started = Date.now();
  watch.status = 'Starting the watch daemon…';
  try {
    const result = await api<WatchStartResponse | ErrorResponse>('/api/watch/start', { method: 'POST', body: '{}' });
    if (!result.response.ok) {
      const error = (result.data as ErrorResponse).error;
      if (error === 'host_unavailable') {
        watch.status = 'Could not start the watch daemon: the editor host stopped; restart boris-editor.';
      } else {
        // 404 (pre-#938 host), watch_unsupported, watch_schema_unsupported,
        // or anything else the host refuses: honest unsupported, no spin.
        markUnsupported();
      }
      return;
    }
    const payload = result.data as WatchStartResponse;
    if (payload.state && payload.state.supported !== false) applyState(payload.state);
    watch.status = payload.status === 'started'
      ? `Watch daemon started. (${elapsedLabel(started)})`
      : payload.status === 'already-running'
        ? 'The watch daemon is already running.'
        : 'The watch daemon is starting with backoff after a failure.';
  } finally {
    watch.inFlight = false;
  }
  // Pull the fresh state and any first events without waiting a tick.
  void pollWatch(true);
}

// Stop is always an explicit click — the shell never auto-stops the daemon.
export async function stopWatchDaemon(): Promise<void> {
  if (watch.supported !== true || watch.inFlight) return;
  watch.inFlight = true;
  const started = Date.now();
  watch.status = 'Stopping the watch daemon…';
  try {
    const result = await api<WatchStopResponse | ErrorResponse>('/api/watch/stop', { method: 'POST', body: '{}' });
    if (!result.response.ok) {
      const error = (result.data as ErrorResponse).error;
      watch.status = error === 'host_unavailable'
        ? 'Could not stop the watch daemon: the editor host stopped; restart boris-editor.'
        : `Could not stop the watch daemon: ${error ?? 'request failed'}.`;
      return;
    }
    const payload = result.data as WatchStopResponse;
    if (payload.state && payload.state.supported !== false) applyState(payload.state);
    watch.status = payload.status === 'stopped'
      ? `Watch daemon stopped. (${elapsedLabel(started)})`
      : 'The watch daemon is not running.';
  } finally {
    watch.inFlight = false;
  }
  void pollWatch(true);
}
