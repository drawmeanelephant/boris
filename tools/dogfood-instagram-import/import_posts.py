#!/usr/bin/env python3
"""Offline Instagram HTML export → Boris Markdown site (dogfood only).

Not a product dependency. Parses Meta export posts_*.html, emits Trunk/Satellite
Markdown + theme shell, copies media into theme/assets/media/.
Never reads messages, security, followers, or ads.
"""

from __future__ import annotations

import argparse
import html
import re
import shutil
import sys
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

POST_SPLIT = re.compile(
    r'(?=<div class="pam _3-95 _2ph- _a6-g uiBoxWhite noborder">)'
)
CAPTION_RE = re.compile(
    r'class="_3-95 _2pim _a6-h _a6-i">(.*?)</div>', re.DOTALL
)
DATE_RE = re.compile(r'class="_3-94 _a6-o">([^<]+)</div>')
SRC_RE = re.compile(r'src="(media/[^"]+)"')
TAG_RE = re.compile(r"<[^>]+>")
HASHTAG_RE = re.compile(r"#([A-Za-z0-9_]+)")
MONTHS = {
    "Jan": 1,
    "Feb": 2,
    "Mar": 3,
    "Apr": 4,
    "May": 5,
    "Jun": 6,
    "Jul": 7,
    "Aug": 8,
    "Sep": 9,
    "Oct": 10,
    "Nov": 11,
    "Dec": 12,
}


@dataclass
class Post:
    caption: str
    date_raw: str
    when: datetime | None
    media: list[str] = field(default_factory=list)
    slug: str = ""
    entity_id: str = ""
    title: str = ""


def parse_date(raw: str) -> datetime | None:
    # e.g. "Nov 19, 2024 7:07 am"
    raw = raw.strip()
    m = re.match(
        r"([A-Za-z]{3})\s+(\d{1,2}),\s+(\d{4})\s+(\d{1,2}):(\d{2})\s*(am|pm)",
        raw,
        re.I,
    )
    if not m:
        return None
    mon = MONTHS.get(m.group(1).title())
    if not mon:
        return None
    hour = int(m.group(4))
    minute = int(m.group(5))
    ampm = m.group(6).lower()
    if ampm == "pm" and hour != 12:
        hour += 12
    if ampm == "am" and hour == 12:
        hour = 0
    return datetime(int(m.group(3)), mon, int(m.group(2)), hour, minute)


def strip_html(fragment: str) -> str:
    text = TAG_RE.sub("", fragment)
    return html.unescape(text).replace("\xa0", " ").strip()


def first_sentence_title(caption: str, max_len: int = 72) -> str:
    line = caption.split("\n", 1)[0].strip()
    for sep in (". ", "! ", "? "):
        if sep in line:
            line = line.split(sep, 1)[0].strip()
            break
    line = re.sub(r"\s+", " ", line)
    if len(line) > max_len:
        line = line[: max_len - 1].rstrip() + "…"
    return line or "Untitled post"


def slugify(when: datetime | None, caption: str, media: list[str], index: int) -> str:
    date_part = when.strftime("%Y-%m-%d") if when else f"undated-{index:04d}"
    # Prefer stable IG media id tail when present
    seed = ""
    if media:
        stem = Path(media[0]).stem
        # ..._n_<longid> style
        m = re.search(r"_(\d{10,})$", stem)
        seed = m.group(1)[-10:] if m else re.sub(r"[^a-z0-9]+", "", stem.lower())[:10]
    if not seed:
        words = re.findall(r"[a-z0-9]+", caption.lower())
        seed = "-".join(words[:4])[:24] or f"post-{index:04d}"
    return f"{date_part}-{seed}"


def yaml_escape(s: str) -> str:
    if re.search(r'[:#"\'\n\\]', s) or s.strip() != s:
        return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'
    return s


def load_posts(dump: Path) -> list[Post]:
    content_dir = dump / "your_instagram_activity" / "content"
    files = sorted(content_dir.glob("posts_*.html"))
    if not files:
        raise SystemExit(f"no posts_*.html under {content_dir}")

    posts: list[Post] = []
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        parts = POST_SPLIT.split(text)
        for part in parts:
            if "uiBoxWhite noborder" not in part:
                continue
            cap_m = CAPTION_RE.search(part)
            date_m = DATE_RE.search(part)
            if not cap_m or not date_m:
                continue
            caption = strip_html(cap_m.group(1))
            if not caption:
                continue
            media = SRC_RE.findall(part)
            # Skip non-post chrome if any
            media = [m for m in media if m.startswith("media/posts/") or m.startswith("media/other/")]
            date_raw = date_m.group(1).strip()
            when = parse_date(date_raw)
            posts.append(
                Post(caption=caption, date_raw=date_raw, when=when, media=media)
            )

    # Export order is newest-first already; keep that for --limit
    for i, p in enumerate(posts):
        p.slug = slugify(p.when, p.caption, p.media, i)
        p.entity_id = f"posts/{p.slug}"
        p.title = first_sentence_title(p.caption)
    return posts


def write_theme(site: Path) -> None:
    theme = site / "theme"
    layouts = theme / "layouts"
    css_dir = theme / "assets" / "css"
    layouts.mkdir(parents=True, exist_ok=True)
    css_dir.mkdir(parents=True, exist_ok=True)

    (theme / "footer.html").write_text(
        '<p class="footer__copy">Private dogfood site · Instagram archive import · not product chrome</p>\n'
        '<p class="footer__meta">Generated offline from a local Meta export · no CDN</p>\n',
        encoding="utf-8",
    )

    (css_dir / "site.css").write_text(
        """/* dogfood site — private; not DaisyUI */
:root {
  color-scheme: light dark;
  --ink: #1a1528;
  --muted: #5c5470;
  --line: #ddd6ec;
  --panel: #f6f3fb;
  --brand: #6419e6;
  --card: #fff;
  font-family: "Segoe UI", system-ui, sans-serif;
  color: var(--ink);
  background: var(--panel);
}
@media (prefers-color-scheme: dark) {
  :root {
    --ink: #f0ebf8;
    --muted: #b4a9c9;
    --line: #3a314f;
    --panel: #120e1c;
    --brand: #b39afa;
    --card: #1c152c;
  }
}
* { box-sizing: border-box; }
body { margin: 0; line-height: 1.65; }
a { color: var(--brand); }
.wrap { max-width: 72rem; margin: 0 auto; padding: 1rem 1.1rem 2rem; }
.navbar { display: flex; flex-wrap: wrap; gap: .75rem 1.25rem; align-items: center; justify-content: space-between; margin-bottom: .75rem; }
.brand { font-weight: 800; letter-spacing: -.01em; text-decoration: none; color: inherit; }
.badge { font-size: .72rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; color: var(--brand); background: color-mix(in oklab, var(--brand) 14%, transparent); padding: .15rem .5rem; border-radius: 999px; }
.shell { display: grid; gap: 1rem; }
@media (min-width: 54rem) { .shell { grid-template-columns: 15rem minmax(0,1fr); } }
.card { background: var(--card); border: 1px solid var(--line); border-radius: .85rem; padding: 1rem 1.1rem; }
.sidebar .label, .rail .label { font-size: .72rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--muted); margin: 0 0 .5rem; }
.site-nav ul { list-style: none; margin: 0; padding: 0; }
.site-nav ul ul { margin: .2rem 0 .4rem .55rem; padding-left: .55rem; border-left: 2px solid var(--line); }
.site-nav a { color: inherit; text-decoration: none; }
.site-nav .is-current > a { font-weight: 700; color: var(--brand); }
.breadcrumb ol { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: .3rem; font-size: .86rem; color: var(--muted); }
.breadcrumb li:not(:last-child)::after { content: "/"; margin-left: .3rem; opacity: .55; }
.page-metadata, .page-toc { background: color-mix(in oklab, var(--panel) 70%, var(--card)); border: 1px solid var(--line); border-radius: .5rem; padding: .7rem .9rem; margin: 0 0 1rem; font-size: .9rem; }
.page-toc ul { list-style: none; margin: 0; padding: 0; }
.page-toc__l2 { padding-left: .8rem; }
.page-toc__l3 { padding-left: 1.6rem; }
.prose img { max-width: 100%; height: auto; border-radius: .6rem; border: 1px solid var(--line); margin: .6rem 0; display: block; }
.prose .gallery { display: grid; gap: .65rem; grid-template-columns: repeat(auto-fit, minmax(12rem, 1fr)); margin: 1rem 0; }
.prose h1 { margin-top: 0; line-height: 1.25; }
.hero { padding: 1.25rem 0 .5rem; }
.hero h1 { margin: 0 0 .4rem; font-size: clamp(1.6rem, 3vw, 2.1rem); }
.hero p { margin: 0; color: var(--muted); max-width: 40rem; }
.footer { margin-top: 1.5rem; padding-top: 1rem; border-top: 1px solid var(--line); color: var(--muted); font-size: .9rem; }
.footer__copy { margin: 0 0 .25rem; font-weight: 600; color: var(--ink); }
.footer__meta { margin: 0; }
.post-meta { color: var(--muted); font-size: .9rem; margin: 0 0 1rem; }
""",
        encoding="utf-8",
    )

    (layouts / "main.html").write_text(
        """<!doctype html>
<html lang="en" data-layout="main">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{title}} · Dogfood</title>
  <link rel="stylesheet" href="{{asset-url assets/css/site.css}}">
</head>
<body data-layout="main">
  <div class="wrap">
    <header class="navbar">
      <a class="brand" href="../index.html">draw me an elephant</a>
      <span class="badge">dogfood</span>
      {{breadcrumb}}
    </header>
    <div class="shell">
      <aside class="card sidebar"><p class="label">Site</p>{{nav}}</aside>
      <main class="card">
        {{metadata}}
        {{toc}}
        <article class="prose">{{content}}</article>
      </main>
    </div>
    <footer class="footer">{{footer}}</footer>
  </div>
</body>
</html>
""",
        encoding="utf-8",
    )

    (layouts / "home.html").write_text(
        """<!doctype html>
<html lang="en" data-layout="home">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{title}} · Dogfood</title>
  <link rel="stylesheet" href="{{asset-url assets/css/site.css}}">
</head>
<body data-layout="home">
  <div class="wrap">
    <header class="hero">
      <p class="badge">private dogfood</p>
      <h1>draw me an elephant</h1>
      <p>Instagram archive spike compiled by Boris — offline media, Trunk/Satellite posts.</p>
    </header>
    <div class="shell">
      <aside class="card sidebar"><p class="label">Site</p>{{nav}}</aside>
      <main class="card">
        {{metadata}}
        <article class="prose">{{content}}</article>
      </main>
    </div>
    <footer class="footer">{{footer}}</footer>
  </div>
</body>
</html>
""",
        encoding="utf-8",
    )

    (layouts / "section.html").write_text(
        """<!doctype html>
<html lang="en" data-layout="section">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{title}} · Dogfood</title>
  <link rel="stylesheet" href="{{asset-url assets/css/site.css}}">
</head>
<body data-layout="section">
  <div class="wrap">
    <header class="navbar">
      <a class="brand" href="index.html">draw me an elephant</a>
      <span class="badge">section</span>
      {{breadcrumb}}
    </header>
    <div class="shell">
      <aside class="card sidebar"><p class="label">In this section</p>{{nav}}</aside>
      <main class="card">
        {{metadata}}
        <article class="prose">{{content}}</article>
      </main>
    </div>
    <footer class="footer">{{footer}}</footer>
  </div>
</body>
</html>
""",
        encoding="utf-8",
    )

    (layouts / "post.html").write_text(
        """<!doctype html>
<html lang="en" data-layout="post">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>{{title}} · Posts · Dogfood</title>
  <link rel="stylesheet" href="{{asset-url assets/css/site.css}}">
</head>
<body data-layout="post">
  <div class="wrap">
    <header class="navbar">
      <a class="brand" href="../index.html">draw me an elephant</a>
      <span class="badge">post</span>
      {{breadcrumb}}
    </header>
    <div class="shell">
      <aside class="card rail"><p class="label">Archive</p>{{nav}}</aside>
      <main class="card">
        {{metadata}}
        <article class="prose">{{content}}</article>
      </main>
    </div>
    <footer class="footer">{{footer}}</footer>
  </div>
</body>
</html>
""",
        encoding="utf-8",
    )


def copy_media(dump: Path, site: Path, posts: list[Post]) -> int:
    """Copy referenced media into theme/assets/media/... ; return file count."""
    n = 0
    assets = site / "theme" / "assets"
    for p in posts:
        for rel in p.media:
            src = dump / rel
            if not src.is_file():
                print(f"warn: missing media {rel}", file=sys.stderr)
                continue
            # theme asset path: assets/<export-relative without media/ prefix? keep media/>
            # Use assets/media/posts/... so Markdown can say ../assets/media/posts/...
            # export rel is media/posts/... → theme assets/media/posts/...
            dest = assets / rel  # assets/media/...
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dest)
            n += 1
    return n


def md_image_path(export_rel: str) -> str:
    # content/posts/foo.md → posts/foo.html → ../assets/media/...
    # export_rel: media/posts/YYYYMM/file.jpg
    return f"../assets/{export_rel}" if not export_rel.startswith("media/") else f"../assets/{export_rel}"


def write_post_markdown(posts_dir: Path, post: Post) -> None:
    tags = ["instagram", "archive"]
    for tag in HASHTAG_RE.findall(post.caption):
        t = tag.lower()
        if t not in tags and len(tags) < 8:
            tags.append(t)
    tag_yaml = "[" + ", ".join(tags) + "]"
    when_iso = post.when.strftime("%Y-%m-%d") if post.when else "unknown"

    body_lines = [
        f"---",
        f"title: {yaml_escape(post.title)}",
        f"parent: posts",
        f"status: published",
        f"tags: {tag_yaml}",
        f"---",
        f"",
        f"# {post.title}",
        f"",
        f'<p class="post-meta">Originally posted {html.escape(post.date_raw)} · imported {when_iso}</p>',
        f"",
    ]

    images = [m for m in post.media if not m.lower().endswith(".mp4")]
    videos = [m for m in post.media if m.lower().endswith(".mp4")]
    if len(images) == 1:
        rel = md_image_path(images[0])
        body_lines += [f"![Post photo]({rel})", ""]
    elif len(images) > 1:
        body_lines += ['<div class="gallery">', ""]
        for i, mpath in enumerate(images, 1):
            rel = md_image_path(mpath)
            body_lines.append(f"![Post photo {i}]({rel})")
        body_lines += ["", "</div>", ""]

    for v in videos:
        body_lines += [
            f"<Aside kind=\"note\">",
            f"",
            f"Video file present in export (`{Path(v).name}`) — not embedded in this spike.",
            f"",
            f"</Aside>",
            f"",
        ]

    # Caption as paragraphs
    for para in re.split(r"\n\s*\n", post.caption.strip()):
        para = para.strip()
        if para:
            body_lines += [para, ""]

    body_lines += [
        "---",
        "",
        f"*Source: local Instagram export · entity `{post.entity_id}`*",
        "",
    ]
    (posts_dir / f"{post.slug}.md").write_text("\n".join(body_lines), encoding="utf-8")


def write_site_pages(content: Path, posts: list[Post], limit: int | None) -> None:
    posts_dir = content / "posts"
    posts_dir.mkdir(parents=True, exist_ok=True)
    # clear previous generated posts only
    for old in posts_dir.glob("*.md"):
        old.unlink()

    for p in posts:
        write_post_markdown(posts_dir, p)

    index_items = "\n".join(
        f"- [{p.title}](posts/{p.slug}.md) — {p.when.strftime('%Y-%m-%d') if p.when else p.date_raw}"
        for p in posts
    )
    scope = f"newest {limit}" if limit else "full archive"
    (content / "index.md").write_text(
        f"""---
title: draw me an elephant
status: published
tags: [home, dogfood]
---

# Home

Private Boris dogfood site built from a local Instagram export ({scope}: **{len(posts)}** posts).

## Browse

- [Posts archive](posts.md)
- [About / other sources](about.md)

## Latest in this import

{index_items}

<Aside kind="tip">

Raw dump stays in `SUPPORT/` (gitignored). Generated site stays in `dogfood/` (gitignored). Product `content/` is untouched.

</Aside>
""",
        encoding="utf-8",
    )

    (content / "posts.md").write_text(
        f"""---
title: Posts
status: published
tags: [posts, instagram]
---

# Posts

Imported Instagram posts as Boris satellites under this trunk.

## In this import ({len(posts)})

{index_items}
""",
        encoding="utf-8",
    )

    (content / "about.md").write_text(
        """---
title: About
status: published
tags: [about]
---

# About

This is a **private dogfood** tree for exercising Boris against a real archive
(draw me an elephant / Instagram).

## Sources

| Source | Status |
|--------|--------|
| Instagram HTML export | Spike import (posts + media only) |
| The list | Not dropped into `SUPPORT/` yet |
| Other notes / exports | TBD |

Device metadata, DMs, followers, and login history from the Meta export are
**not** imported.
""",
        encoding="utf-8",
    )


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument(
        "--dump",
        type=Path,
        required=True,
        help="Path to Instagram export root (contains your_instagram_activity/)",
    )
    ap.add_argument(
        "--out",
        type=Path,
        default=Path("dogfood/site"),
        help="Site root to write (default: dogfood/site)",
    )
    ap.add_argument(
        "--limit",
        type=int,
        default=None,
        help="Import only the newest N posts (export order)",
    )
    args = ap.parse_args()
    dump: Path = args.dump
    if not dump.is_dir():
        raise SystemExit(f"dump not found: {dump}")

    all_posts = load_posts(dump)
    posts = all_posts[: args.limit] if args.limit else all_posts
    if not posts:
        raise SystemExit("no posts parsed")

    # de-dupe slugs
    seen: dict[str, int] = {}
    for p in posts:
        base = p.slug
        n = seen.get(base, 0)
        seen[base] = n + 1
        if n:
            p.slug = f"{base}-{n+1}"
            p.entity_id = f"posts/{p.slug}"

    site: Path = args.out
    if site.exists():
        # preserve out/; wipe content/posts + rewrite theme shell
        pass
    site.mkdir(parents=True, exist_ok=True)
    content = site / "content"
    content.mkdir(parents=True, exist_ok=True)

    write_theme(site)
    media_n = copy_media(dump, site, posts)
    write_site_pages(content, posts, args.limit)

    print(f"posts_imported={len(posts)} of {len(all_posts)}")
    print(f"media_copied={media_n}")
    print(f"content={content}")
    print(f"theme={site / 'theme'}")


if __name__ == "__main__":
    main()
