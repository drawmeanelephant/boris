# Accessibility notes

What this theme guarantees in its own HTML and CSS. It does not replace a
manual screen-reader, keyboard, zoom, or contrast review of a rendered site.

- **Skip link.** Every layout opens with "Skip to main content" targeting
  `#main-content`.
- **Landmarks.** A body-level `header`, one `main`, a labelled "On this
  page" `aside` (or the home rail), and a body-level `footer`.
- **Focus.** Two-tone focus in the public-service style. Links get a yellow
  `#ffdd00` fill with black text (14.55:1) and a black underline bar;
  other controls get a 0.2rem black outline inside a yellow halo. One of the
  two tones clears 3:1 on every surface: black on the light page (17.52:1),
  yellow on the dark page (12.68:1) and the blue masthead (9.21:1). The
  previous yellow-only outline measured 1.20:1 on the light page.
- **Contrast.** Ink `#0b0c0c` on `#f3f2f1` is 17.52:1; links `#1d70b8` are
  4.62:1 on the page and 5.17:1 on white. In dark mode links switch to
  `#5694ca` (5.27:1 on `#1b1c1c`, 4.63:1 on the dark surface); the previous
  `#1d70b8` measured 3.30:1 and 2.90:1. Inline code no longer keeps a white
  background under light dark-mode text. Status tags are 7.77:1 (draft),
  6.16:1 (published), and 8.57:1 (archived).
- **Not colour alone.** Status tags keep their word; relation kinds are
  captions in words; callouts keep a text title.
- **Motion.** `prefers-reduced-motion: reduce` disables smooth scrolling and
  clamps transitions and animations.
- **Print.** `@media print` resets the palette to black on white even for
  dark-mode readers, hides the header, footer, contents rail, and skip link,
  flattens the grid to one column, and wraps code.
- **Narrow screens.** Below 48rem the grid stacks and the contents rail stops
  being sticky.
- **Search hygiene.** `data-boris-search-root` on `main`. Captions, the
  children section, contents rails, relations, and the layout `<h1>` (which
  has no id, so its stored fragment could not resolve) carry
  `data-boris-search-exclude`.
- **Known limitation.** The document `<title>` is the static word "Service"
  on every page because the layouts use their single `{{title}}` slot for
  the visible `<h1>` (WCAG 2.4.2 Page Titled is not met). Recorded for a
  design decision rather than silently changed.
