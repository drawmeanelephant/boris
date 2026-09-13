<script lang="ts">
  import type { Problem, GraphNode } from '../lib/types';
  import { buffer, dirty, editSource, undo, redo, trackCursor } from '../lib/state/buffer.svelte';
  import { density } from '../lib/state/density.svelte';
  import { activeProblems, staleProblems } from '../lib/state/problems.svelte';
  import { problemLocationLabel } from '../lib/utils';
  import AuthoringTools from './AuthoringTools.svelte';
  import GraphPane from './GraphPane.svelte';
  import RecipePane from './RecipePane.svelte';
  import ThemePane from './ThemePane.svelte';
  import PublicationPane from './PublicationPane.svelte';

  let {
    onSave,
    onNavigate,
    onOpenFile,
    onOpenGraphNode,
    onImpact,
    onScale,
    onReset,
    onRunPlan,
    onVerifyProof,
    onExportGraph,
    onEnterFocus
  }: {
    onSave: () => void;
    onNavigate: (problem: Problem) => void;
    onOpenFile: (path: string) => void;
    onOpenGraphNode: (node: GraphNode | null) => void;
    onImpact: () => void;
    onScale: () => void;
    onReset: () => void;
    onRunPlan: () => void;
    onVerifyProof: () => void;
    onExportGraph: () => void;
    onEnterFocus: (trigger: HTMLElement | null) => void;
  } = $props();

  let focusEntry = $state() as HTMLButtonElement | undefined;

  // --- Writing chrome (#989) ------------------------------------------------
  // The source surface stays a native textarea — the editing authority. The
  // chrome around it is presentation only: a caret-ruler gutter, a
  // current-line band, and a frontmatter/body seam.
  //
  // All geometry is measured from a hidden mirror that holds the buffer
  // verbatim with identical wrapping metrics, the same technique Focus
  // writing mode uses for its paragraph bands. Rects come back in mirror
  // content coordinates, so positioning a band means subtracting the
  // textarea's own scrollTop; the gutter and band layers apply that as one
  // shared translate, and scrolling never re-renders the numbers.
  //
  // The gutter numbers the lines whose boxes have actually been measured for
  // the visible window — a wrapped line cannot drift them, and a region that
  // has not been measured yet shows nothing rather than a guess. The current
  // line is the one measured fact always in hand, so it is highlighted.
  let shell = $state() as HTMLDivElement | undefined;
  let surface = $state() as HTMLDivElement | undefined;
  let mirror = $state() as HTMLDivElement | undefined;
  let editor = $state() as HTMLTextAreaElement | undefined;
  let gutterInner = $state() as HTMLDivElement | undefined;
  let linesInner = $state() as HTMLDivElement | undefined;

  type GutterLine = { line: number; top: number };

  let gutterLines = $state<GutterLine[]>([]);
  let currentBand = $state<{ top: number; height: number } | null>(null);
  let frontmatterSeam = $state<{ top: number } | null>(null);

  // Content-coordinate measurements for the current buffer revision. Edits
  // clear them; scrolling never does.
  let lastContent = '';
  const lineTops = new Map<number, number>();
  const lineStarts = new Map<number, number>();

  // Bounded walk so a pathological document cannot stall a scroll frame.
  const WALK_LIMIT = 1200;

  function measuredLineHeight(): number {
    if (!mirror) return 20;
    const value = Number.parseFloat(getComputedStyle(mirror).lineHeight);
    return Number.isFinite(value) && value > 0 ? value : 20;
  }

  function charRect(offset: number): { top: number; bottom: number } | null {
    const node = mirror?.firstChild;
    if (!mirror || !node || node.nodeType !== Node.TEXT_NODE || buffer.content.length === 0) return null;
    const start = Math.max(0, Math.min(offset, buffer.content.length - 1));
    const end = Math.min(start + 1, buffer.content.length);
    const range = document.createRange();
    range.setStart(node, start);
    range.setEnd(node, end);
    const mirrorBox = mirror.getBoundingClientRect();
    for (const rect of range.getClientRects()) {
      if (rect.height === 0 && rect.width === 0) continue;
      return { top: rect.top - mirrorBox.top, bottom: rect.bottom - mirrorBox.top };
    }
    return null;
  }

  function measureTop(line: number, start: number): number | null {
    const known = lineTops.get(line);
    if (known !== undefined) return known;
    // A trailing empty line (content ends in "\n") starts below the final
    // character's own line box, not at it.
    const rect = start >= buffer.content.length
      ? charRect(buffer.content.length - 1)
      : charRect(start);
    if (!rect) return null;
    const top = start >= buffer.content.length ? rect.bottom : rect.top;
    lineTops.set(line, top);
    return top;
  }

  function startOfLine(line: number): number {
    if (line <= 1) return 0;
    let anchorLine = 1;
    let anchorOffset = 0;
    for (const [known, offset] of lineStarts) {
      if (known <= line && known > anchorLine) {
        anchorLine = known;
        anchorOffset = offset;
      }
    }
    let offset = anchorOffset;
    for (let index = anchorLine; index < line; index += 1) {
      const newline = buffer.content.indexOf('\n', offset);
      if (newline === -1) break;
      offset = newline + 1;
    }
    lineStarts.set(line, offset);
    return offset;
  }

  function previousLineStart(start: number): number {
    if (start <= 0) return 0;
    const searchEnd = start - 2;
    if (searchEnd < 0) return 0;
    return buffer.content.lastIndexOf('\n', searchEnd) + 1;
  }

  function nextLineStart(start: number): number | null {
    if (start >= buffer.content.length) return null;
    const newline = buffer.content.indexOf('\n', start);
    return newline === -1 ? null : newline + 1;
  }

  function nearestCachedLine(target: number): number | null {
    let best: number | null = null;
    let bestTop = -Infinity;
    for (const [line, top] of lineTops) {
      if (top <= target && top > bestTop) {
        best = line;
        bestTop = top;
      }
    }
    if (best !== null) return best;
    let minTop = Infinity;
    for (const [line, top] of lineTops) {
      if (top < minTop) {
        minTop = top;
        best = line;
      }
    }
    return best;
  }

  function coverViewport(scrollTop: number, viewBottom: number) {
    if (!mirror || buffer.content.length === 0) return;
    const lineHeight = measuredLineHeight();
    const topLimit = scrollTop - lineHeight * 2;
    const bottomLimit = viewBottom + lineHeight * 2;
    const anchorLine = nearestCachedLine(scrollTop) ?? Math.max(1, buffer.cursor.line);
    const anchorStart = startOfLine(anchorLine);
    const anchorTop = measureTop(anchorLine, anchorStart);
    if (anchorTop === null) return;

    let line = anchorLine;
    let start = anchorStart;
    let top = anchorTop;
    let steps = 0;
    while (top < bottomLimit && steps < WALK_LIMIT) {
      const next = nextLineStart(start);
      if (next === null) break;
      line += 1;
      start = next;
      const nextTop = measureTop(line, start);
      if (nextTop === null) break;
      top = nextTop;
      steps += 1;
    }

    line = anchorLine;
    start = anchorStart;
    top = anchorTop;
    steps = 0;
    while (top > topLimit && line > 1 && steps < WALK_LIMIT) {
      const previous = previousLineStart(start);
      if (previous === start) break;
      line -= 1;
      start = previous;
      const previousTop = measureTop(line, start);
      if (previousTop === null) break;
      top = previousTop;
      steps += 1;
    }
  }

  function cachedLinesInView(scrollTop: number, viewBottom: number): GutterLine[] {
    const lineHeight = measuredLineHeight();
    const visible: GutterLine[] = [];
    for (const [line, top] of lineTops) {
      if (top >= scrollTop - lineHeight && top <= viewBottom + lineHeight) visible.push({ line, top });
    }
    visible.sort((a, b) => a.top - b.top);
    return visible;
  }

  function syncScrollPositions() {
    const top = editor?.scrollTop ?? 0;
    if (gutterInner) gutterInner.style.transform = `translateY(${-top}px)`;
    if (linesInner) linesInner.style.transform = `translateY(${-top}px)`;
  }

  function caretLineStart(): number {
    if (editor && document.activeElement === editor) {
      const offset = Math.max(0, Math.min(editor.selectionStart, buffer.content.length));
      if (offset <= 0) return 0;
      return buffer.content.lastIndexOf('\n', offset - 1) + 1;
    }
    return startOfLine(Math.max(1, buffer.cursor.line));
  }

  // Presentation-only frontmatter seam: a leading `---` fenced block closed
  // by `---`/`...` before the body. This reads fence *shape* only — no key or
  // value parsing — so it can never become a second frontmatter grammar.
  // Anything it does not recognize simply shows no seam.
  function frontmatterSeamOffset(content: string): number | null {
    if (!content.startsWith('---\n') && !content.startsWith('---\r\n')) return null;
    const lines = content.split('\n');
    for (let index = 1; index < lines.length; index += 1) {
      const line = lines[index].endsWith('\r') ? lines[index].slice(0, -1) : lines[index];
      if (line !== '---' && line !== '...') continue;
      let offset = 0;
      for (let cursor = 0; cursor <= index; cursor += 1) offset += lines[cursor].length + 1;
      return Math.min(offset, content.length);
    }
    return null;
  }

  function syncChrome() {
    const area = editor;
    if (!mirror || !area || !buffer.activePath || buffer.content.length === 0) {
      gutterLines = [];
      currentBand = null;
      frontmatterSeam = null;
      if (mirror && area) syncScrollPositions();
      return;
    }
    const scrollTop = area.scrollTop;
    const viewBottom = scrollTop + area.clientHeight;
    coverViewport(scrollTop, viewBottom);
    gutterLines = cachedLinesInView(scrollTop, viewBottom);

    const caretTop = measureTop(Math.max(1, buffer.cursor.line), caretLineStart());
    currentBand = caretTop === null || buffer.readOnly
      ? null
      : { top: caretTop, height: measuredLineHeight() };

    const seamOffset = frontmatterSeamOffset(buffer.content);
    frontmatterSeam = seamOffset === null ? null : (() => {
      const rect = charRect(Math.min(seamOffset, buffer.content.length - 1));
      return rect ? { top: rect.top } : null;
    })();

    syncScrollPositions();
  }

  function handleInput(event: Event) {
    editSource(event);
    trackCursor();
  }

  let coverageQueued = false;

  function handleScroll() {
    syncScrollPositions();
    if (coverageQueued) return;
    coverageQueued = true;
    requestAnimationFrame(() => {
      coverageQueued = false;
      const area = editor;
      if (!area) return;
      coverViewport(area.scrollTop, area.scrollTop + area.clientHeight);
      gutterLines = cachedLinesInView(area.scrollTop, area.scrollTop + area.clientHeight);
    });
  }

  // Re-measure after DOM mutations and caret moves. The mirror is updated by
  // Svelte before effects run, so its metrics match the rendered text.
  $effect(() => {
    const content = buffer.content;
    const cursorLine = buffer.cursor.line;
    const cursorColumn = buffer.cursor.column;
    const activePath = buffer.activePath;
    void buffer.readOnly;
    void activePath;
    void cursorLine;
    void cursorColumn;
    if (content !== lastContent) {
      lastContent = content;
      lineTops.clear();
      lineStarts.clear();
    }
    syncChrome();
  });

  // A width or height change rewraps the mirror: re-measure what is visible.
  $effect(() => {
    const area = editor;
    if (!area) return;
    const observer = new ResizeObserver(() => {
      const live = editor;
      if (!live) return;
      coverViewport(live.scrollTop, live.scrollTop + live.clientHeight);
      gutterLines = cachedLinesInView(live.scrollTop, live.scrollTop + live.clientHeight);
      syncScrollPositions();
    });
    observer.observe(area);
    return () => observer.disconnect();
  });
</script>

<section id="source" class="source-pane" tabindex="-1" aria-labelledby="source-heading">
  <div class="pane-heading">
    <div>
      <h2 id="source-heading">Source</h2>
      <p class="path">{buffer.activePath || 'No file selected'}</p>
    </div>
    <div class="source-actions" aria-label="Editing actions">
      <button
        type="button"
        class="quiet"
        bind:this={focusEntry}
        onclick={() => onEnterFocus(focusEntry ?? null)}
        title="Expand to a full-screen writing surface (Esc returns)"
      >Focus</button>
      <button type="button" class="quiet" disabled={buffer.undoStack.length === 0 || buffer.readOnly} onclick={undo}>Undo</button>
      <button type="button" class="quiet" disabled={buffer.redoStack.length === 0 || buffer.readOnly} onclick={redo}>Redo</button>
      <button type="button" class="primary" disabled={!dirty() || buffer.readOnly || buffer.saveInFlight} onclick={onSave}>Save file</button>
    </div>
  </div>
  {#if buffer.activePath}
    <label for="source-editor">Source for {buffer.activePath}</label>
    <div class="source-editor-shell" class:readonly={buffer.readOnly} bind:this={shell}>
      <div class="source-gutter" aria-hidden="true">
        <div class="source-gutter-inner" bind:this={gutterInner}>
          {#each gutterLines as entry (entry.line)}
            <span
              class="source-gutter-line"
              class:current={entry.line === buffer.cursor.line}
              style:top="{entry.top}px"
            >{entry.line}</span>
          {/each}
        </div>
      </div>
      <div class="source-surface" bind:this={surface}>
        <div class="source-mirror" bind:this={mirror} aria-hidden="true">{buffer.content}</div>
        <div class="source-lines" aria-hidden="true">
          <div class="source-lines-inner" bind:this={linesInner}>
            {#if currentBand}
              <span class="source-current-line" style:top="{currentBand.top}px" style:height="{currentBand.height}px"></span>
            {/if}
            {#if frontmatterSeam}
              <span class="source-frontmatter-seam" style:top="{frontmatterSeam.top}px">
                <span class="source-seam-label">frontmatter ends</span>
              </span>
            {/if}
          </div>
        </div>
        <textarea
          id="source-editor"
          bind:this={editor}
          value={buffer.content}
          readonly={buffer.readOnly}
          spellcheck="false"
          oninput={handleInput}
          onselect={trackCursor}
          onclick={trackCursor}
          onkeyup={trackCursor}
          onscroll={handleScroll}
        ></textarea>
      </div>
    </div>
    <div class="source-status-line">
      <span class="source-caret" aria-label="Caret position">Line {buffer.cursor.line}, column {buffer.cursor.column}</span>
      <span class:warning={dirty() || buffer.readOnly} class="buffer-state">
        {buffer.readOnly ? 'Read-only file' : dirty() ? 'Unsaved changes' : 'Saved on disk'}
      </span>
    </div>
    <AuthoringTools collapsed={density.mode === 'author'} />
  {:else}
    <p>Choose a file from Project files. Generated output and editor state are intentionally excluded.</p>
  {/if}
  {#if density.mode === 'review'}
    <GraphPane
      onOpenPath={onOpenFile}
      onOpenNode={onOpenGraphNode}
      onImpact={onImpact}
      onExport={onExportGraph}
    />
  {/if}
  {#if buffer.activePath}
    <RecipePane
      onScale={onScale}
      onReset={onReset}
      onOpenNode={onOpenGraphNode}
    />
    <ThemePane
      onOpenFile={onOpenFile}
      onNavigate={onNavigate}
    />
    {#if activeProblems().length > 0}
      <aside class="inline-problems" aria-label="Problems in {buffer.activePath}">
        <h3>Problems in this file</h3>
        <ul>
          {#each activeProblems() as problem}
            <li>
              <button type="button" onclick={() => onNavigate(problem)}>
                Go to {problemLocationLabel(problem)}: {problem.code ?? 'Unstructured Boris output'}
              </button>
              {#if staleProblems().has(problem)}
                <p class="warning-text">Possibly stale — the open buffer changed this region since the report.</p>
              {/if}
            </li>
          {/each}
        </ul>
      </aside>
    {/if}
  {/if}
  <p role="status" aria-label="Editing status" aria-live="polite">{buffer.editorStatus}</p>
  {#if density.mode === 'review'}
    <PublicationPane onRunPlan={onRunPlan} onVerifyProof={onVerifyProof} />
  {/if}
</section>
