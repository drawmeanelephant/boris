<script lang="ts">
  // Section navigation for the editor shell (#941): the links stay plain
  // hash anchors (the href is the no-JS fallback), and the component layers
  // feedback mechanics on top:
  //  - focus hand-off: the click focuses the target section (tabindex="-1"
  //    programmatic-focus targets) so the next Tab continues from where the
  //    author landed;
  //  - arrival highlight: a transient .arrived pulse class on the landed
  //    section (CSS keyframes; collapsed by the reduced-motion block);
  //  - scrollspy: keeps aria-current="true" and the active pill on the link
  //    whose section is nearest the reading top;
  //  - edge affordances: edge bars hint a scrollable pill row on narrow
  //    viewports, and the active pill scrolls into view. The bars are
  //    siblings of the scrollable row (not children) so they never scroll
  //    away or clip with the content.
  //  - unavailable targets: a nav link whose pane is absent (Graph only
  //    exists once a file is open) is presented disabled and explains
  //    itself on activation instead of silently doing nothing (#944).
  type SectionLink = { id: string; label: string };

  type Props = {
    // Section ids whose target pane is currently absent, mapped to a short
    // human reason. Absent targets render aria-disabled with the reason as
    // their title; activation is a no-op that reports the reason.
    unavailable?: Record<string, string>;
    // Receives the reason for a click on an unavailable target; App routes
    // it to the editing-status live region.
    onBlockedNav?: (reason: string) => void;
  };

  let { unavailable = {}, onBlockedNav }: Props = $props();

  const links: SectionLink[] = [
    { id: 'project', label: 'Project' },
    { id: 'source', label: 'Source' },
    { id: 'graph', label: 'Graph' },
    { id: 'publication', label: 'Publication' },
    { id: 'problems', label: 'Problems' },
    { id: 'preview', label: 'Preview' },
    { id: 'watch', label: 'Watch' }
  ];

  const ARRIVAL_MS = 1600;

  let nav = $state() as HTMLElement | undefined;
  let row = $state() as HTMLElement | undefined;
  // Mirror of the DOM .arrived class for assertion and cleanup; the class on
  // the section element is what the CSS pulse keys on.
  let arrived = $state<string | null>(null);
  let current = $state<string | null>(null);
  let canScrollStart = $state(false);
  let canScrollEnd = $state(false);

  let arrivedTimer: ReturnType<typeof setTimeout> | undefined;
  let resyncTimer: ReturnType<typeof setTimeout> | undefined;
  let arrivedElement: HTMLElement | undefined;

  function sectionFor(id: string): HTMLElement | null {
    return document.getElementById(id);
  }

  function clearArrival() {
    arrivedElement?.classList.remove('arrived');
    arrivedElement = undefined;
    arrived = null;
  }

  // The jump has happened (or is about to); anchor focus on the target and
  // pulse the arrival. preventScroll because scrollIntoView already placed
  // the section; focusing without it would re-scroll and can fight the
  // smooth behavior.
  function announceArrival(id: string) {
    const section = sectionFor(id);
    if (!section) return;
    clearArrival();
    section.focus({ preventScroll: true });
    // Force a style flush so a rapid second click restarts the keyframes.
    void section.offsetWidth;
    section.classList.add('arrived');
    arrivedElement = section;
    arrived = id;
    clearTimeout(arrivedTimer);
    arrivedTimer = setTimeout(clearArrival, ARRIVAL_MS);
  }

  // The URL fragment is this editor's launch channel (#943): the session
  // token rides in it (api.ts parses it once at startup), and `open` is
  // consumed at launch. Writing the section id must preserve the
  // still-relevant params, not swap the whole fragment — a bare `#${id}`
  // would leave a reload token-missing. `open` is deliberately dropped:
  // carrying it forward would re-open the file on every reload.
  function sectionFragment(id: string): string {
    const params = new URLSearchParams(window.location.hash.slice(1));
    const next = new URLSearchParams();
    const token = params.get('token');
    if (token) next.set('token', token);
    // Section id last so the fragment reads as the live location.
    next.set('section', id);
    return next.toString();
  }

  // Focus hand-off plus feedback on plain clicks: modifier-clicks fall
  // through to the browser (new tab/window), keyboard activation goes
  // through the same click event. preventDefault plus the manual jump keeps
  // URL and behavior in one place; href remains the no-JS fallback.
  function handleNav(event: MouseEvent, id: string) {
    if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    // An absent target never jumps and never touches the URL (#944); the
    // reason goes to the App's live region so the no-op says why. Enter on
    // a focused link lands here too.
    const reason = unavailable[id];
    if (reason) {
      event.preventDefault();
      onBlockedNav?.(reason);
      return;
    }
    const section = sectionFor(id);
    if (!section) return;
    event.preventDefault();
    history.replaceState(null, '', `#${sectionFragment(id)}`);
    // Honor the reduced-motion contract in JS too: the CSS block collapses
    // transitions/animations, but scrollIntoView('smooth') is scripted and
    // would still animate.
    const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
    section.scrollIntoView({ behavior: reduced ? 'auto' : 'smooth', block: 'start' });
    announceArrival(id);
    // Activation feedback is instant: currency points at the intended
    // target now, and the scroll listener re-asserts viewport truth as the
    // (smooth) jump settles — or as soon as the author scrolls again.
    current = id;
    clearTimeout(resyncTimer);
    resyncTimer = setTimeout(syncCurrent, 600);
  }

  function updateEdges() {
    const el = row;
    if (!el) return;
    canScrollStart = el.scrollLeft > 1;
    canScrollEnd = el.scrollLeft + el.clientWidth < el.scrollWidth - 1;
  }

  // Scrollspy, classic rule: the current section is the one nearest the
  // reading line from above; re-read per scroll frame (cheap for seven
  // sections). The line sits a nav height below where scrollIntoView parks a
  // landed section (scroll-margin-top already includes the nav height, so the
  // cushion is deliberate slack, not the park position). Above every section
  // (page top), the journey starts at the first link so wayfinding never
  // reads as "nowhere".
  function syncCurrent() {
    // Bottom rule (standard scrollspy behavior): at max scroll the last
    // present section is current, because a short page or the footer clamp
    // can keep it from ever reaching the reading line.
    const maxScroll = document.documentElement.scrollHeight - window.innerHeight;
    if (maxScroll > 0 && window.scrollY >= maxScroll - 1) {
      for (let i = links.length - 1; i >= 0; i--) {
        if (sectionFor(links[i].id)) {
          current = links[i].id;
          return;
        }
      }
    }
    // Reading line: the last section whose top edge has reached it wins;
    // above every section (page top), the journey starts at the first link
    // so wayfinding never reads as "nowhere".
    const navHeight = nav?.offsetHeight ?? 64;
    // Pick the qualifying section *nearest* the line, not the last one in
    // `links` order. `links` is a logical order, but the panes sit in three
    // columns — Project and Source, with Graph and Publication nested inside
    // Source, and Problems/Preview/Watch in the rail. A column can therefore
    // hold a section that is later in `links` yet higher on screen, and
    // ordering by `links` handed currency to a section parked off the top of
    // another column after a jump (a jump to Graph settled on Preview).
    // Nearest-to-the-line is order-independent: it agrees with the ordered
    // rule whenever order matches the layout, and is correct when it does not.
    let best: string | null = null;
    let bestTop = -Infinity;
    for (const { id } of links) {
      const section = sectionFor(id);
      if (!section) continue;
      const margin = parseFloat(getComputedStyle(section).scrollMarginTop) || 0;
      const top = section.getBoundingClientRect().top;
      // 1px tolerance: a landed section can rest a subpixel below the line
      // after scrollIntoView rounding, which must not hand currency back to
      // the section behind it. Ties keep the earlier link.
      if (top <= navHeight + margin + 1 && top > bestTop) {
        best = id;
        bestTop = top;
      }
    }
    current = best ?? links[0].id;
  }

  $effect(() => {
    const navEl = nav;
    const rowEl = row;
    if (!navEl || !rowEl) return;
    // Expose the measured nav height so pane scroll-margin-top can sit the
    // landed section just below the sticky bar without a hardcoded constant.
    const setHeight = () => document.documentElement.style.setProperty('--section-nav-h', `${navEl.offsetHeight}px`);
    setHeight();
    updateEdges();
    syncCurrent();
    const onScroll = () => syncCurrent();
    const onRowScroll = () => updateEdges();
    const onResize = () => { setHeight(); onScroll(); };
    // The workspace rail is a second scroll container at ≥80rem (overflow-y:
    // auto): its inner scrolling moves Problems/Preview/Watch in viewport
    // coordinates without any window scroll, so the spy must listen there
    // too or aria-current goes stale. Queried live — the rail is App-owned
    // chrome, not a component prop; at narrower widths it never scrolls, so
    // the listener is simply quiet.
    const rail = document.querySelector('.workspace-rail');
    window.addEventListener('scroll', onScroll, { passive: true });
    window.addEventListener('resize', onResize, { passive: true });
    rowEl.addEventListener('scroll', onRowScroll, { passive: true });
    rail?.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      window.removeEventListener('scroll', onScroll);
      window.removeEventListener('resize', onResize);
      rowEl.removeEventListener('scroll', onRowScroll);
      rail?.removeEventListener('scroll', onScroll);
      document.documentElement.style.removeProperty('--section-nav-h');
    };
  });

  // Keep the active pill reachable on narrow viewports: when the current
  // section changes (through scrolling or a jump), bring its link into the
  // clipped pill row instead of leaving it scrolled out of reach. This
  // adjusts the row's scrollLeft directly — link.scrollIntoView() would
  // also scroll ancestor viewports, and a sticky nav's link layout position
  // sits above the viewport when scrolled down, so it would fight the very
  // scroll that changed the current section.
  $effect(() => {
    if (!current || !row) return;
    const link = row.querySelector<HTMLAnchorElement>(`a[href="#${current}"]`);
    if (link) {
      const left = link.offsetLeft;
      const right = left + link.offsetWidth;
      if (left < row.scrollLeft + parseFloat(getComputedStyle(link).marginLeft || '0')) {
        row.scrollLeft = left;
      } else if (right > row.scrollLeft + row.clientWidth) {
        row.scrollLeft = right - row.clientWidth;
      }
    }
    updateEdges();
  });

  $effect(() => () => {
    clearTimeout(arrivedTimer);
    clearTimeout(resyncTimer);
  });
</script>

<nav
  class="section-nav"
  class:scroll-start={canScrollStart}
  class:scroll-end={canScrollEnd}
  data-arrived={arrived ?? ''}
  aria-label="Editor sections"
  bind:this={nav}
>
  <div class="section-nav-row" bind:this={row}>
    {#each links as { id, label } (id)}
      <a
        href="#{id}"
        onclick={(event) => handleNav(event, id)}
        aria-current={current === id ? 'true' : undefined}
        aria-disabled={unavailable[id] ? 'true' : undefined}
        title={unavailable[id]}
      >{label}</a>
    {/each}
  </div>
  <span class="section-nav-fade section-nav-fade-start" aria-hidden="true"></span>
  <span class="section-nav-fade section-nav-fade-end" aria-hidden="true"></span>
</nav>
