<script lang="ts">
  import { fade } from 'svelte/transition';
  import { prefersReducedMotion } from 'svelte/motion';
  import { buffer, dirty, editSource, undo, redo } from '../lib/state/buffer.svelte';
  import {
    focusMode,
    setFocusLayout,
    focusType,
    setFocusTypeSize,
    setFocusTypeMeasure,
    setFocusTypeFace,
    focusZen,
    setFocusZenTypewriter,
    setFocusZenDim,
    type FocusTypeSize,
    type FocusMeasure,
    type FocusTypeFace
  } from '../lib/state/focus.svelte';
  import { preview } from '../lib/state/preview.svelte';
  import { renderMarkdown } from '../lib/markdown';

  let {
    onSave,
    onRebuild,
    onExit
  }: {
    onSave: () => void;
    onRebuild: () => void;
    onExit: () => void;
  } = $props();

  let textarea = $state() as HTMLTextAreaElement | undefined;
  let reading = $state() as HTMLDivElement | undefined;
  let editorShell = $state() as HTMLDivElement | undefined;
  let underlay = $state() as HTMLDivElement | undefined;
  let mirror = $state() as HTMLDivElement | undefined;

  const showEditor = () => focusMode.layout !== 'preview';
  const showReading = () => focusMode.layout !== 'write';

  // Without an open buffer there is nothing to write: the overlay renders an
  // honest empty state instead of an editor bound to nothing.
  const hasBuffer = $derived(buffer.activePath !== '');

  // The reading aid re-renders on every keystroke; the renderer is bounded
  // (single pass, capped input) so this stays instant on normal documents.
  const readingHtml = $derived(renderMarkdown(buffer.content));

  const wordCount = $derived(
    buffer.content.trim() === '' ? 0 : buffer.content.trim().split(/\s+/).length
  );

  $effect(() => {
    if (reading) reading.innerHTML = readingHtml;
  });

  // Land focus in the writing surface when the overlay opens (or the reading
  // surface in preview-only layout), so the writing experience starts
  // keyboard-first like a word processor.
  $effect(() => {
    if (!focusMode.open) return;
    void (async () => {
      await new Promise(resolve => setTimeout(resolve, 0));
      if (showEditor()) {
        textarea?.focus();
        updateLocalCursor();
      } else {
        reading?.focus();
      }
    })();
  });

  // --- Paragraph model -------------------------------------------------------
  // The buffer splits into display paragraphs at blank lines (flat offsets are
  // exact buffer.content coordinates, excluding the separator runs). This is
  // presentation geometry for the dimming aid, not a re-parse of the source.
  type Segment = { start: number; end: number; text: string };

  const segments = $derived.by(() => {
    const out: Segment[] = [];
    const content = buffer.content;
    let start = 0;
    while (start <= content.length) {
      let i = start;
      while (i < content.length && content[i] !== '\n') i += 1;
      out.push({ start, end: i, text: content.slice(start, i) });
      if (i >= content.length) break;
      while (i < content.length && content[i] === '\n') i += 1;
      start = i;
    }
    return out;
  });

  // The caret offset tracked from the focus textarea's own selection events.
  // This is deliberately local to the overlay: the shell's cursor tracker
  // reads the workspace #source-editor, which is not the element the author
  // is typing into here.
  let localCursor = $state(-1);

  function updateLocalCursor() {
    if (!textarea) return;
    localCursor = textarea.selectionStart;
    buffer.cursor = cursorFor(textarea.selectionStart);
  }

  function cursorFor(offset: number): { line: number; column: number } {
    const before = buffer.content.slice(0, offset);
    const lines = before.split('\n');
    return { line: lines.length, column: lines[lines.length - 1].length + 1 };
  }

  function handleEditorInput(event: Event) {
    editSource(event);
    updateLocalCursor();
  }

  const activeSegment = $derived.by(() => {
    if (localCursor < 0) return null;
    for (const seg of segments) {
      if (localCursor >= seg.start && localCursor <= seg.end) return seg;
    }
    return null;
  });

  // --- Writing assists --------------------------------------------------------
  // Both aids measure the caret and paragraph bands through a hidden mirror
  // element that holds the buffer verbatim (pre-wrap) with identical font,
  // padding, and border metrics as the textarea — so a DOM Range over the
  // mirror's text node maps 1:1 to textarea content coordinates. The dim
  // aid applies an inverted mask over an absolutely positioned veil so only
  // the caret's paragraph band stays bright; typewriter scrolling centers
  // the caret line.
  function syncAssist() {
    if (!editorShell || !textarea || !mirror) return;
    const editorActive = showEditor() && hasBuffer;
    if (!editorActive) {
      setVeil(0, null);
      return;
    }

    // Force layout so measurements reflect the latest content and styles.
    // getClientRects() values are viewport-relative at the current scroll,
    // so subtracting the editor's own viewport origin yields coordinates in
    // the textarea's visible box — exactly the underlay's mask box.
    const editorRect = textarea.getBoundingClientRect();
    const view = textarea.clientHeight;

    const caretRect = rangeRect(localCursor, localCursor);
    let band: { top: number; bottom: number } | null = null;
    if (activeSegment) {
      band = rangeRect(activeSegment.start, activeSegment.end);
    }
    if (!band && caretRect) {
      band = { top: caretRect.top, bottom: caretRect.bottom };
    }
    if (focusZen.typewriter && caretRect) {
      // Typewriter first: caretCenter is the caret's unscrolled content
      // coordinate relative to the shell top, so centering means
      // scrollTop = caret − half the view. The dim mask below must be
      // computed against the post-scroll offset to stay aligned.
      const caretCenter = (caretRect.top + caretRect.bottom) / 2 - editorRect.top;
      const target = caretCenter - view / 2;
      const maxScroll = Math.max(0, textarea.scrollHeight - view);
      textarea.scrollTop = Math.min(Math.max(0, target), maxScroll);
    }

    if (focusZen.dim && band) {
      // The underlay's mask box is the shell's visible box, so the band must
      // be expressed in scrolled viewport coordinates: mirror rects are
      // unscrolled content coordinates, and the textarea's scrollTop is the
      // difference between the two.
      const pad = 6;
      const bandTop = band.top - editorRect.top - textarea.scrollTop;
      const bandBottom = band.bottom - editorRect.top - textarea.scrollTop;
      const y0 = Math.max(0, bandTop - pad);
      const y1 = Math.min(view, bandBottom + pad);
      // The veil paints everywhere except the caret's band. mask-image takes
      // <image> values only — shapes like polygon() belong to clip-path — so
      // the window is a hard-stop gradient: opaque (veil visible) outside the
      // band, transparent (bright window) inside it.
      if (y0 <= 0 && y1 >= view) {
        // The caret's paragraph fills the view: nothing left to veil.
        setVeil(0, null);
      } else {
        let mask: string;
        if (y0 <= 0) {
          mask = `linear-gradient(to bottom, transparent 0 ${y1}px, #000 ${y1}px 100%)`;
        } else if (y1 >= view) {
          mask = `linear-gradient(to bottom, #000 0 ${y0}px, transparent ${y0}px 100%)`;
        } else {
          mask = `linear-gradient(to bottom, #000 0 ${y0}px, transparent ${y0}px ${y1}px, #000 ${y1}px 100%)`;
        }
        setVeil(1, mask);
      }
    } else if (focusZen.dim) {
      // Dim on but nothing to anchor to (empty buffer edge): honest full veil.
      setVeil(1, null);
    } else {
      setVeil(0, null);
    }
  }

  function rangeRect(start: number, end: number): { top: number; bottom: number } | null {
    const node = mirror?.firstChild;
    if (!mirror || !node) return null;
    const clampedStart = Math.max(0, Math.min(start, buffer.content.length));
    const clampedEnd = Math.max(0, Math.min(end, buffer.content.length));
    if (clampedEnd < clampedStart) return null;
    try {
      const range = document.createRange();
      range.setStart(node, clampedStart);
      range.setEnd(node, clampedEnd);
      let rects = range.getClientRects();
      // A collapsed caret range can yield an empty rect list; widen to the
      // enclosing line so the aid still has geometry to anchor to.
      if (rects.length === 0 && clampedStart === clampedEnd && clampedStart > 0) {
        range.setStart(node, clampedStart - 1);
        range.setEnd(node, clampedStart);
        rects = range.getClientRects();
      }
      if (rects.length === 0) return null;
      let top = Infinity;
      let bottom = -Infinity;
      for (const rect of rects) {
        if (rect.height === 0 && rect.top === 0 && rect.left === 0) continue;
        top = Math.min(top, rect.top);
        bottom = Math.max(bottom, rect.bottom);
      }
      return top === Infinity ? null : { top, bottom };
    } catch {
      return null;
    }
  }

  function setVeil(opacity: number, mask: string | null) {
    if (!editorShell || !underlay) return;
    editorShell.style.setProperty('--zen-underlay', String(opacity));
    if (mask !== null) {
      underlay.style.webkitMaskImage = mask;
      underlay.style.maskImage = mask;
    } else {
      underlay.style.removeProperty('-webkit-mask-image');
      underlay.style.removeProperty('mask-image');
    }
  }

  $effect(syncAssist);

  function handleWindowKeydown(event: KeyboardEvent) {
    if (!focusMode.open) return;
    if (document.querySelector('dialog[open]')) return;
    if (event.key === 'Escape') {
      event.preventDefault();
      onExit();
      return;
    }
    // Plain arrows outside any interactive control still move the caret, so
    // a stray click on the overlay never traps keyboard navigation. Arrows on
    // buttons/radios keep their native behavior (radio groups use them).
    const active = document.activeElement;
    const interactive = active instanceof HTMLElement
      && (['BUTTON', 'INPUT', 'SELECT', 'TEXTAREA'].includes(active.tagName)
        || active.isContentEditable
        || active.getAttribute('role') === 'option');
    if (
      showEditor() &&
      !interactive &&
      !event.metaKey &&
      !event.ctrlKey &&
      !event.altKey &&
      ['ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight'].includes(event.key)
    ) {
      event.preventDefault();
      const step = event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 1;
      const pos = step < 0
        ? Math.max(0, textarea!.selectionStart - 1)
        : Math.min(buffer.content.length, textarea!.selectionEnd + 1);
      textarea!.setSelectionRange(pos, pos);
      textarea!.focus();
      updateLocalCursor();
    }
  }
</script>

<svelte:window onkeydown={handleWindowKeydown} />

<div
  class="focus-overlay"
  role="dialog"
  aria-modal="true"
  aria-label="Focus writing mode"
  transition:fade={{ duration: prefersReducedMotion.current ? 0 : 150 }}
>
  <header class="focus-chrome">
    <div class="focus-title">
      <h2>Focus</h2>
      <p class="path">{buffer.activePath || 'No file selected'}</p>
    </div>
    <fieldset class="focus-layouts">
      <legend>Layout</legend>
      <label><input type="radio" name="focus-layout" value="write" checked={focusMode.layout === 'write'} onchange={() => setFocusLayout('write')} /> Write</label>
      <label><input type="radio" name="focus-layout" value="split" checked={focusMode.layout === 'split'} onchange={() => setFocusLayout('split')} /> Split</label>
      <label><input type="radio" name="focus-layout" value="preview" checked={focusMode.layout === 'preview'} onchange={() => setFocusLayout('preview')} /> Preview</label>
    </fieldset>
    <details class="focus-type">
      <summary>Typography</summary>
      <div class="focus-type-grid">
        <fieldset class="focus-type-group">
          <legend>Text size</legend>
          <label><input type="radio" name="focus-type-size" value="s" checked={focusType.size === 's'} onchange={() => setFocusTypeSize('s' as FocusTypeSize)} /> S</label>
          <label><input type="radio" name="focus-type-size" value="m" checked={focusType.size === 'm'} onchange={() => setFocusTypeSize('m' as FocusTypeSize)} /> M</label>
          <label><input type="radio" name="focus-type-size" value="l" checked={focusType.size === 'l'} onchange={() => setFocusTypeSize('l' as FocusTypeSize)} /> L</label>
          <label><input type="radio" name="focus-type-size" value="xl" checked={focusType.size === 'xl'} onchange={() => setFocusTypeSize('xl' as FocusTypeSize)} /> XL</label>
        </fieldset>
        <fieldset class="focus-type-group">
          <legend>Line width</legend>
          <label><input type="radio" name="focus-type-measure" value="narrow" checked={focusType.measure === 'narrow'} onchange={() => setFocusTypeMeasure('narrow' as FocusMeasure)} /> Narrow</label>
          <label><input type="radio" name="focus-type-measure" value="medium" checked={focusType.measure === 'medium'} onchange={() => setFocusTypeMeasure('medium' as FocusMeasure)} /> Medium</label>
          <label><input type="radio" name="focus-type-measure" value="wide" checked={focusType.measure === 'wide'} onchange={() => setFocusTypeMeasure('wide' as FocusMeasure)} /> Wide</label>
        </fieldset>
        <fieldset class="focus-type-group">
          <legend>Typeface</legend>
          <label><input type="radio" name="focus-type-face" value="serif" checked={focusType.face === 'serif'} onchange={() => setFocusTypeFace('serif' as FocusTypeFace)} /> Serif</label>
          <label><input type="radio" name="focus-type-face" value="sans" checked={focusType.face === 'sans'} onchange={() => setFocusTypeFace('sans' as FocusTypeFace)} /> Sans</label>
        </fieldset>
      </div>
    </details>
    <details class="focus-type focus-aids">
      <summary>Writing aids</summary>
      <div class="focus-type-grid focus-aids-grid">
        <fieldset class="focus-type-group">
          <legend>Typewriter scrolling</legend>
          <label><input type="radio" name="focus-zen-typewriter" value="on" aria-label="Typewriter scrolling on" checked={focusZen.typewriter} onchange={() => setFocusZenTypewriter(true)} /> On</label>
          <label><input type="radio" name="focus-zen-typewriter" value="off" aria-label="Typewriter scrolling off" checked={!focusZen.typewriter} onchange={() => setFocusZenTypewriter(false)} /> Off</label>
        </fieldset>
        <fieldset class="focus-type-group">
          <legend>Paragraph dimming</legend>
          <label><input type="radio" name="focus-zen-dim" value="on" aria-label="Paragraph dimming on" checked={focusZen.dim} onchange={() => setFocusZenDim(true)} /> On</label>
          <label><input type="radio" name="focus-zen-dim" value="off" aria-label="Paragraph dimming off" checked={!focusZen.dim} onchange={() => setFocusZenDim(false)} /> Off</label>
        </fieldset>
      </div>
    </details>
    <div class="focus-actions">
      <button type="button" disabled={buffer.undoStack.length === 0 || buffer.readOnly} onclick={undo}>Undo</button>
      <button type="button" disabled={buffer.redoStack.length === 0 || buffer.readOnly} onclick={redo}>Redo</button>
      <button type="button" class="primary" disabled={!dirty() || buffer.readOnly || buffer.saveInFlight} onclick={onSave}>Save file</button>
      <button
        type="button"
        disabled={preview.data?.phase === 'running'}
        onclick={onRebuild}
        title="Rebuild the compiled Boris preview (live in the workspace Preview pane)"
      >Rebuild preview</button>
      <button type="button" onclick={onExit} aria-keyshortcuts="Escape" title="Exit focus mode (Esc)">Exit focus</button>
    </div>
  </header>

  <div class="focus-surface" data-layout={focusMode.layout} data-size={focusType.size} data-measure={focusType.measure} data-face={focusType.face}>
    {#if !hasBuffer}
      <div class="focus-reading" aria-label="Focus mode empty state" tabindex="-1">
        <h3>No file is open</h3>
        <p>Choose a file from Project files (Esc returns to the workspace) and re-enter focus mode to write.</p>
      </div>
    {:else}
    {#if showEditor()}
      <div class="focus-editor-shell" bind:this={editorShell}>
        <div class="zen-underlay" bind:this={underlay} aria-hidden="true"></div>
        <label class="visually-hidden-text" for="focus-editor">Focus writing surface for {buffer.activePath || 'the selected file'}</label>
        <textarea
          id="focus-editor"
          bind:this={textarea}
          class="focus-editor"
          value={buffer.content}
          readonly={buffer.readOnly}
          spellcheck="false"
          aria-label={`Focus writing surface for ${buffer.activePath || 'the selected file'}${focusZen.dim ? ' · paragraph focus dimming on' : ''}`}
          oninput={handleEditorInput}
          onselect={updateLocalCursor}
          onclick={updateLocalCursor}
          onkeyup={updateLocalCursor}
        ></textarea>
        <div class="focus-mirror" bind:this={mirror} aria-hidden="true">{buffer.content}</div>
      </div>
    {/if}
    {#if showReading()}
      <div
        class="focus-reading"
        bind:this={reading}
        tabindex="-1"
        role="document"
        aria-label="Reading preview of the open buffer"
      ></div>
    {/if}
    {/if}
  </div>

  <footer class="focus-status">
    <span class="focus-words">{wordCount} {wordCount === 1 ? 'word' : 'words'}</span>
    <span class="focus-caret">Line {buffer.cursor.line}, column {buffer.cursor.column}</span>
    <span class:warning={dirty() || buffer.readOnly}>{buffer.readOnly ? 'Read-only file' : dirty() ? 'Unsaved changes' : 'Saved on disk'}</span>
    <span class="focus-live">Boris preview build status: {preview.data?.phase ?? 'idle'}</span>
    <p role="status" aria-label="Editing status" aria-live="polite" class="focus-editor-status">{buffer.editorStatus}</p>
  </footer>
</div>
