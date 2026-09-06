// editor/ui/src/lib/markdown.ts
// A bounded, dependency-free Markdown preview for the focus-mode writing
// surface. It renders the subset of Oliver's grammar an author types while
// writing — ATX headings, paragraphs, emphasis, inline code, fenced code
// blocks, block quotes, lists, thematic breaks, wiki links, and the authoring
// vocabulary's Aside tokens — as semantic HTML for the sandboxed reading
// frame.
//
// This is a *reading aid*, not a second pipeline: it never claims to be the
// compiled page (the Preview pane and `boris watch` own that truth). It
// exists so focus mode can show live, near-instant feedback while writing.
//
// Safety model: every text run passes through escapeHtml before it can reach
// an HTML string, and only `http(s):` link targets become real anchors —
// wiki links and relative references render as styled, non-navigable spans,
// because the aid has no compiled route graph to resolve them against. The
// result is assigned via innerHTML into a div in the top document, NOT a
// sandboxed iframe; the invariant that makes that sound is total escaping
// plus the http(s)-only anchor policy (pinned by e2e assertions), not frame
// sandboxing. If a future change wants to relax either half of that policy,
// move the reading surface into a sandboxed iframe first.

const ASIDE_VARIANTS = new Set(['note', 'warning', 'tip', 'danger']);

const BLOCKED_SCHEME = /^(javascript|data|vbscript):/i;

export function escapeHtml(text: string): string {
  return text
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

type InlineMatch =
  | { kind: 'code'; match: RegExpExecArray }
  | { kind: 'wiki'; match: RegExpExecArray }
  | { kind: 'link'; match: RegExpExecArray };

function earliestInline(text: string): InlineMatch | null {
  const code = /`([^`]+)`/.exec(text);
  const wiki = /\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/.exec(text);
  const link = /\[([^\]]+)\]\(([^)\s]+)\)/.exec(text);
  const candidates: Array<{ kind: 'code' | 'wiki' | 'link'; match: RegExpExecArray }> = [];
  if (code) candidates.push({ kind: 'code', match: code });
  if (wiki) candidates.push({ kind: 'wiki', match: wiki });
  if (link) candidates.push({ kind: 'link', match: link });
  candidates.sort((a, b) => a.match.index - b.match.index);
  return candidates[0] ?? null;
}

/** Real anchor only for http(s) targets; everything else stays plain text. */
function anchorOrText(label: string, target: string, wiki: boolean): string {
  const trimmed = target.trim();
  const escapedLabel = escapeHtml(label);
  if (!trimmed || BLOCKED_SCHEME.test(trimmed)) return escapedLabel;
  if (!/^https?:\/\//i.test(trimmed)) {
    // Not resolvable in the reading aid: render honestly as non-navigable.
    return wiki
      ? `<span class="focus-wikilink">${escapedLabel}</span>`
      : escapedLabel;
  }
  const href = encodeURI(trimmed);
  return `<a href="${escapeHtml(href)}" target="_blank" rel="noreferrer">${escapedLabel}</a>`;
}

/** Inline pass: code spans, wiki links, links, then emphasis over the rest. */
function renderInline(text: string): string {
  let out = '';
  let rest = text;
  while (rest.length > 0) {
    const hit = earliestInline(rest);
    if (!hit) {
      out += emphasis(escapeHtml(rest));
      break;
    }
    out += emphasis(escapeHtml(rest.slice(0, hit.match.index)));
    const m = hit.match;
    if (hit.kind === 'code') {
      out += `<code>${escapeHtml(m[1])}</code>`;
    } else if (hit.kind === 'wiki') {
      const target = m[1];
      const label = (m[2] ?? m[1]).trim();
      out += anchorOrText(label, target, true);
    } else {
      out += anchorOrText(m[1], m[2], false);
    }
    rest = rest.slice(m.index + m[0].length);
  }
  return out;
}

/** Bold/italic over already-escaped text; `**` and `*` survive escaping. */
function emphasis(escaped: string): string {
  return escaped
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/(^|[^*])\*([^*]+)\*/g, '$1<em>$2</em>');
}

/**
 * Renders the bounded Markdown subset to an HTML string. Every text run is
 * escaped and only http(s) targets become anchors (see the safety model
 * above); e2e tests pin both halves of that invariant.
 */
export function renderMarkdown(source: string): string {
  const lines = source.replaceAll('\r\n', '\n').split('\n');
  const blocks: string[] = [];

  // Frontmatter: nearly every Boris page opens with a YAML block, and left
  // in place it renders as thematic-break noise plus stray paragraphs. The
  // reading aid is a prose preview, so the block renders once as a muted,
  // collapsed band instead of body text.
  if (lines[0]?.trim() === '---') {
    let end = 1;
    while (end < lines.length && lines[end].trim() !== '---') end += 1;
    if (end < lines.length) {
      const entries = lines.slice(1, end).filter(l => l.trim() !== '');
      const summary = entries.length > 0
        ? `frontmatter · ${entries.length} ${entries.length === 1 ? 'key' : 'keys'}`
        : 'frontmatter';
      blocks.push(
        `<details class="focus-frontmatter"><summary>${escapeHtml(summary)}</summary><pre><code>${escapeHtml(lines.slice(1, end).join('\n'))}</code></pre></details>`
      );
      return renderBody(blocks, lines.slice(end + 1));
    }
  }

  return renderBody(blocks, lines);
}

function renderBody(blocks: string[], lines: string[]): string {

  let i = 0;
  let paragraph: string[] = [];

  const flushParagraph = () => {
    if (paragraph.length > 0) {
      blocks.push(`<p>${renderInline(paragraph.join(' '))}</p>`);
      paragraph = [];
    }
  };

  while (i < lines.length) {
    const line = lines[i];
    const trimmed = line.trim();

    // Fenced code block (``` or ~~~ with an optional info string).
    const fence = /^(```|~~~)\s*([^\s`]*)\s*$/.exec(trimmed);
    if (fence) {
      flushParagraph();
      const marker = fence[1];
      const lang = fence[2];
      const body: string[] = [];
      i += 1;
      while (i < lines.length && lines[i].trim() !== marker) {
        body.push(lines[i]);
        i += 1;
      }
      i += 1; // consume the closing fence (or run off the end)
      const langClass = lang ? ` class="language-${escapeHtml(lang)}"` : '';
      blocks.push(`<pre><code${langClass}>${escapeHtml(body.join('\n'))}</code></pre>`);
      continue;
    }

    // Aside token: opens with :::variant, closes with :::, per the authoring
    // vocabulary. Inner content renders as inline Markdown paragraphs.
    const aside = /^:::([a-z]+)\s*$/.exec(trimmed);
    if (aside && ASIDE_VARIANTS.has(aside[1])) {
      flushParagraph();
      const variant = aside[1];
      const body: string[] = [];
      i += 1;
      while (i < lines.length && lines[i].trim() !== ':::') {
        body.push(lines[i]);
        i += 1;
      }
      i += 1;
      const inner = body
        .join('\n')
        .split(/\n{2,}/)
        .filter(part => part.trim() !== '')
        .map(part => `<p>${renderInline(part.replaceAll('\n', ' ').trim())}</p>`)
        .join('');
      blocks.push(
        `<aside class="focus-aside focus-aside-${variant}"><p class="focus-aside-title">${variant}</p>${inner}</aside>`
      );
      continue;
    }

    // ATX heading.
    const heading = /^(#{1,6})\s+(.*)$/.exec(line);
    if (heading) {
      flushParagraph();
      const level = heading[1].length;
      blocks.push(`<h${level}>${renderInline(heading[2].trim())}</h${level}>`);
      i += 1;
      continue;
    }

    // Block quote.
    if (line.startsWith('>')) {
      flushParagraph();
      const quote: string[] = [];
      while (i < lines.length && lines[i].startsWith('>')) {
        quote.push(lines[i].replace(/^>\s?/, ''));
        i += 1;
      }
      blocks.push(`<blockquote><p>${renderInline(quote.join(' ').trim())}</p></blockquote>`);
      continue;
    }

    // Thematic break. Checked before lists: CommonMark gives the break
    // precedence when a line could parse as either, and the break may be
    // spaced (`* * *`, `- - -`).
    if (/^\s*(?:-{3,}|\*{3,}|-\s*-\s*-|\*\s*\*\s*\*)\s*$/.test(trimmed)) {
      flushParagraph();
      blocks.push('<hr>');
      i += 1;
      continue;
    }

    // Unordered list (one level; nesting is beyond the reading aid).
    if (/^\s*[-*]\s+/.test(line)) {
      flushParagraph();
      const items: string[] = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^\s*[-*]\s+/, '').trim())}</li>`);
        i += 1;
      }
      blocks.push(`<ul>${items.join('')}</ul>`);
      continue;
    }

    // Ordered list (one level).
    if (/^\s*\d+\.\s+/.test(line)) {
      flushParagraph();
      const items: string[] = [];
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) {
        items.push(`<li>${renderInline(lines[i].replace(/^\s*\d+\.\s+/, '').trim())}</li>`);
        i += 1;
      }
      blocks.push(`<ol>${items.join('')}</ol>`);
      continue;
    }

    // Blank line ends the paragraph.
    if (trimmed === '') {
      flushParagraph();
      i += 1;
      continue;
    }

    paragraph.push(trimmed);
    i += 1;
  }
  flushParagraph();

  return blocks.join('\n');
}
