---
title: Frontmatter Reference
parent: reference
status: published
tags: [reference, frontmatter]
---

<p class="eyebrow">Grammar</p>

# Frontmatter Reference {#frontmatter}

<Aside kind="warning">

Unknown keys fail closed. `parentEntry` is not an alias. It is an
`EFRONTMATTER` error.

</Aside>

Boris frontmatter is a small, closed, line-oriented grammar. It is not general
YAML: unknown keys, nested mappings, multiline values, comments, and unsupported
list forms fail with `EFRONTMATTER`.

Frontmatter is optional. It is recognized only when `---` is the complete first
line at byte zero and ends at a matching line. A file without frontmatter is
still a page; its entity id comes from its path.

## Accepted keys

Exactly these nine author-facing keys are accepted. The set is still closed.

| Key | Type | Default | Meaning |
|---|---|---|---|
| `id` | string | path-derived id | Override the entity id; it must be unique and path-safe |
| `title` | string | unset | Display title; layouts fall back to the entity id when needed |
| `parent` | string | unset | Direct parent entity id; omission makes a Trunk |
| `status` | enum | unset | `draft`, `published`, or `archived` |
| `tags` | list | `[]` | Bounded list of plain or double-quoted tag strings |
| `relations` | list | `[]` | Typed semantic relations such as `relates_to=target` |
| `published_at` | UTC timestamp | unset | Exact `YYYY-MM-DDTHH:MM:SSZ`; requires `summary` |
| `summary` | string | unset | One-line summary, 1–1,024 bytes |
| `servings` | count | unset (scale treats current as 1) | Cooklang convention: how many people the recipe is for |

`serves` and `yield` are the only aliases, and they mean `servings`. Every
other Cooklang metadata name (`source`, `author`, `course`, `time`, …) is
still `EFRONTMATTER`. `parentEntry` and `parent_entry` stay unknown. This is
not open YAML.

## Examples

Minimal Trunk:

```markdown
---
title: Getting Started
status: published
tags: [setup, cli]
---

# Getting Started
```

Satellite with publication metadata and a semantic relation:

```markdown
---
id: guides/release-notes
title: Release Notes
parent: guides/overview
status: published
tags: [release]
relations: [supersedes=guides/old-release]
published_at: 2026-08-09T12:00:00Z
summary: Changes in the current documentation release.
---
```

`published_at` is an exact UTC value, not a free-form date. `summary` may be
provided without `published_at`; the pair is required for an RSS item.

## `id`

Without an explicit id, Boris derives one from the page path:

```text
content/guides/building-pages.md → guides/building-pages
```

Entity ids use `/`-separated non-empty segments. They cannot be absolute, use
backslashes, contain `.` or `..` segments, or include a fragment/query suffix.
The output route is the entity id with `.html` appended; there is no directory
index mapping.

## `title`

Titles are optional. When present, a title is a one-line string (at most 512
UTF-8 bytes) used by navigation, breadcrumbs, HTML `<title>`, IR, and machine
projections. A page with no title remains valid; the layout's `{{title}}`
marker uses its entity id as the display fallback.

## `parent` and page roles

```yaml
parent: guides/overview
```

`parent` names the exact direct parent entity id, not a filename, title, or
directory label. Omitting it makes the page a **Trunk**. Supplying it makes the
page a **Satellite**. Satellites may have Satellites, so nested finite acyclic
chains are valid. Missing parents, self-parents, duplicate ids, and cycles fail
before publication.

## `status`

The only values are:

```yaml
status: draft
status: published
status: archived
```

Draft pages are excluded from published projections. `published`, `archived`,
and an omitted status remain eligible for normal compiler projections; RSS also
requires `published_at` and `summary`.

## `tags` and `relations`

Tags use the bounded bracket form:

```yaml
tags: [setup, "quick start", cli]
```

Semantic relations use `kind=target` entries:

```yaml
relations: [relates_to=guides/overview, implements=reference/commands]
```

The supported relation kinds are `relates_to`, `implements`, `depends_on`, and
`supersedes`. Relations are not parent edges, navigation edges, wiki-links, or
dependency edges for `check` and `impact`.

## Grammar boundaries

Accepted values are one-line plain or double-quoted scalars, plus the named
`tags` and `relations` lists. These forms are rejected:

- single-quoted values, YAML comments, anchors, aliases, and block scalars;
- indented/nested fields, sequence items, and multiline values;
- arbitrary keys such as `author`, `layout`, or `sidebar_position`;
- legacy parent names `parentEntry` and `parent_entry`.

Values are byte-bounded, and duplicate keys are errors. The parser accepts LF
and CRLF line endings but requires valid UTF-8 and rejects a leading BOM.

## Troubleshooting

```text
error: EFRONTMATTER: content/page.md:4:1: unknown key "sidebar_position"
```

1. Run `boris validate --input content` to exercise the HTML compiler path
   without writing output.
2. Remove unknown keys or rewrite them using the eight-key grammar above.
3. Run `boris build` once the preflight is clean.

Use `boris check` for graph-health analysis after compiler validation; it is not
an alias for `validate`.

## Related pages

- [[guides/building-pages|Building Pages]] — authoring workflow
- [[reference/relationships|Relationships]] — parent, wiki, include, and semantic edges
- [[reference/diagnostics|Diagnostics & Troubleshooting]] — stable error codes
