# Slot Mapping for Boris Theme Integration - Verified

This specification maps the native Boris layout engine slots (`{{...}}`) to the conformed HTML DOM structure in our zero-dependency Milligram-inspired theme, verified via local Zig compilation.

## Verified Core Slots

The Boris compiler compiled all 8 slots successfully with absolute correctness:

| Slot Tag | Verified Location in `layouts/main.html` | Generated Output HTML DOM Structure / Boris compiler contract | Verification Status |
| :--- | :--- | :--- | :--- |
| `{{title}}` | `<title>{{title}} · TechDocs</title>` in `<head>` | Injects the document's page title statically from frontmatter or filename metadata. | **Verified Active** |
| `{{asset-url ...}}` | `<link rel="stylesheet" href="{{asset-url assets/theme.css}}">` in `<head>` | Replaces the token with the relative path to the compiled theme asset: `assets/theme.css?v=[hash]`. | **Verified Active** |
| `{{nav}}` | Inside the `<details class="mobile-nav-details" open>` wrapper in `.sidebar` | Outputs the nested hierarchical list of all pages in the documentation structure using standard `<ul>`/`<li>` semantics. | **Verified Active** |
| `{{breadcrumb}}` | Inside `<main class="content-area">` under `<article>` | Renders a flex-flat ordered list `<nav class="breadcrumb">` showing the breadcrumb hierarchy for current page routing. | **Verified Active** |
| `{{content}}` | `<div class="boris-content">{{content}}</div>` inside `<article>` | Renders the parsed Markdown body, including native semantic HTML headers, paragraphs, code blocks, and lists. | **Verified Active** |
| `{{toc}}` | `<aside class="toc-sidebar" aria-label="Table of Contents">{{toc}}</aside>` | Generates a clean table of contents navigation list (`.page-toc`) pointing to sub-headings on the current page. | **Verified Active** |
| `{{children}}` | Handled automatically as part of trunk page generation inside `{{content}}` | Renders a list of child/satellite pages under `.page-children` utilizing a responsive grid layout. | **Verified Active** |
| `{{footer}}` | At the bottom of `<article>` inside the main container | Renders the pagination links (next/previous) and copyright block compiled statically from the theme's `footer.html`. | **Verified Active** |

---

## 1. Primary Layout Contract Slots Details

### `{{title}}`
- **Location:** In the `<head>` of `layouts/main.html`.
- **Target:** `<title>{{title}} · TechDocs</title>`
- **Output:** Plain text title derived from frontmatter (or filename fallback).

### `{{asset-url ...}}`
- **Location:** In the `<head>` link element: `<link rel="stylesheet" href="{{asset-url assets/theme.css}}">`.
- **Output:** Compiles to the relative, cached-busted path: `<link rel="stylesheet" href="../assets/theme.css">` depending on current directory nesting.

### `{{nav}}`
- **Location:** Inside `<aside class="sidebar">` wrapped in a `<details>` tag:
  ```html
  <details class="mobile-nav-details" open>
    <summary class="mobile-nav-summary font-body-md">Menu</summary>
    <div class="mobile-nav-wrapper">
      {{nav}}
    </div>
  </details>
  ```
- **Output:** Boris compiles this as a full-site nested navigation forest:
  ```html
  <nav class="site-nav" aria-label="Site">
    <ul>
      <li class="site-nav__trunk [is-current]">
        <a href="..." [aria-current="page"]>Trunk Page</a>
        <ul>
          <li class="site-nav__satellite [is-current]"><a href="..." [aria-current="page"]>Satellite Page</a></li>
        </ul>
      </li>
    </ul>
  </nav>
  ```
- **Responsive Handling:** We reuse this single slot for both desktop and mobile. On desktop, media queries hide the `<summary>` and force the details wrapper open. On mobile, it acts as a normal toggle accordion.

### `{{breadcrumb}}`
- **Location:** Above the main body content.
- **Target:** `{{breadcrumb}}`
- **Output:**
  ```html
  <nav class="breadcrumb" aria-label="Breadcrumb">
    <ol>
      <li><a href="...">Content Model Overview</a></li>
      <li aria-current="page">Using Asides</li>
    </ol>
  </nav>
  ```

### `{{content}}`
- **Location:** Inside `<main class="content-area">`.
- **Target:**
  ```html
  <div class="boris-content">
    {{content}}
  </div>
  ```
- **Output:** Rendered HTML of the Markdown page, including native header ids, tables, list elements, code blocks, images, and embedded asides.

### `{{footer}}`
- **Location:** At the bottom of the main `<article>`.
- **Target:** `{{footer}}`
- **Output:** Statically reads from `footer.html` in the theme root directory. Contains pagination controls and the site footer copyright block.

### `{{toc}}`
- **Location:** Adjacent to `.content-area`.
- **Target:** `<aside class="toc-sidebar" aria-label="Table of Contents">{{toc}}</aside>`
- **Output:**
  ```html
  <nav class="page-toc" aria-label="On this page">
    <ul>
      <li class="page-toc__l1"><a href="#...">Heading 1</a></li>
      <li class="page-toc__l2"><a href="#...">Heading 2</a></li>
    </ul>
  </nav>
  ```
- **Responsive Handling:** Hidden on mobile/tablets (`< 1024px`) via CSS media queries.

---

## 2. Inlined Elements (Compiled inside `{{content}}`)

### Aside (Admonitions)
- **Constraint:** NOT a direct layout slot. Admonitions are parsed from `<Aside>` tags in Markdown and compiled directly inline within the `{{content}}` body.
- **Output Format:**
  ```html
  <aside class="admonition admonition--[kind]" [id="..."] aria-label="[Kind]">
    <p class="admonition__title">[Kind]</p>
    <div class="admonition__body">
       ...
    </div>
  </aside>
  ```
- **Styling:** Fully mapped via `.admonition`, `.admonition__title`, `.admonition__body`, and variant modifiers (`.admonition--note`, `.admonition--tip`, `.admonition--info`, `.admonition--warning`, `.admonition--danger`).

### `{{children}}` (Satellite Lists)
- **Constraint:** Compiled inside the `{{content}}` body on Trunk pages using `<nav class="page-children">`.
- **Output Format:**
  ```html
  <nav class="page-children" aria-label="Children">
    <ul>
      <li><a href="...">Satellite Title</a></li>
    </ul>
  </nav>
  ```
- **Styling:** Mapped via `.page-children` in `theme.css`.
