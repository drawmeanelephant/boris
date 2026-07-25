# mini-instagram fixture

Synthetic **Instagram data-download** (Takeout-style) tree for
`boris-migration-lab --mode=instagram`. Not a real export; no personal data.

```text
mini-instagram/
  your_instagram_activity/content/
    posts_1.json      # posts: simple, carousel, video, missing, dup basenames, unicode, empty, no-title
    posts_2.json      # multipart export + Meta's escaped Latin-1/UTF-8 caption form
    reels.json
    stories.json
    other_content.json
  media/
    posts/202401|202402/…
    reels/202401/…
    stories/202401/…
```

## Coverage

| Signal | Record |
|--------|--------|
| Simple photo | first posts_1 entry |
| Carousel (2 images) | second |
| Video | third |
| Missing media | fourth |
| Duplicate basenames (different dirs) | fifth + sixth |
| Unicode caption | seventh |
| Empty media / deleted-like | eighth |
| Caption-less media | ninth |
| Meta escaped caption | `posts_2.json` — repaired to valid UTF-8 and marked in provenance |
| Reel | reels.json |
| Story | stories.json |
| Unknown other archive | other_content.json |

## Run

```bash
# from tools/migration-lab/
zig build run -- --mode=instagram --dump=./fixtures/mini-instagram --out=./.ig-report
zig build test
```

Source files under this fixture are **never rewritten** by the tool.
