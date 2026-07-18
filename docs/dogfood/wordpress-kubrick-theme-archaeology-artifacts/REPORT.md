# WordPress theme archaeology report

This is a deterministic, read-only scan of a small classic-WordPress-shaped fixture. The fixture is **not** an authentic Kubrick release and this tool never executes PHP.

## Evidence boundary

The lab sees filenames, bytes, hashes, and source-line text. It does not run PHP, load WordPress, resolve hooks, inspect plugins/database state, render a browser, fetch remote assets, or claim universal WordPress compatibility. Every detected dynamic behavior is retained in `manual_review.json`.

## Inventory

| Path | Classification | Bytes | SHA-256 |
|---|---|---:|---|
| `README.md` | `other` | 985 | `a238f2bbf694ef7740c0851295468c8d3b574e1e0fd331595513c05f9c7b803e` |
| `comments.php` | `comments` | 160 | `12479fb7b5c5df1cc63791820bd49c92d7585a3aabbfd9121ca8ca2c83c19c55` |
| `footer.php` | `footer` | 179 | `de5d8428dba056fe74c6fc3fcf56be5764e3409ba25c1bb00639f2331b6e3dbe` |
| `functions.php` | `functions` | 799 | `55a7bfb2e2357b4c718bbf239da3ff0baa4095507f9022005ddc79b6b399ec65` |
| `header.php` | `header` | 442 | `0d1d5a6602dece65d476792532a157bd2a61af3d0a88aefb86f4ab604a46ce08` |
| `images/logo.svg` | `asset` | 230 | `fc8f889c4bf883ac82fdddc9ad1686d0cb7e6120707ab0741e8286e1e98ec806` |
| `images/screenshot.png` | `asset` | 55 | `334baecc5c485a9ebd73949a14a12965e7150577e298e29b45b162353dd5f0bf` |
| `index.php` | `index` | 386 | `b5b57b80f5c9cf401d5a7a179119906f410441a6e7000edc739e766649990da2` |
| `js/menu.js` | `asset` | 255 | `30909fa58f39f8085b8b1481aab4c18aad6b43140b61acc892cf8cdb214f8b9c` |
| `page.php` | `page` | 316 | `5b4c9c18c87beb4273a5468e788a53c41118094943dfb1d0433c59aa5682bacb` |
| `rtl.css` | `asset` | 25 | `c2d84b5666c106df63657b62fa42bd02d203c551864c9d3de4555760e9a74c33` |
| `searchform.php` | `search_form` | 309 | `dc1cd8edbe6d11000f3d378f3edbcb3fcb961383369b8efbea7c74e3ca06c8b0` |
| `sidebar.php` | `sidebar` | 284 | `7864866e429784ce0b7fa136890eaef2fb6e1f13d74bd63031d6c7865af9bce0` |
| `single.php` | `single` | 413 | `b42591930fdd01926439a0215beb25f0e496ee4116a01de43af5b14afc978225` |
| `style.css` | `stylesheet` | 523 | `a06db9a9359402858a57467418ed6e76ddfb49dece79babe04c6c585c145ab1c` |

## Prototype slot decisions

| Boris surface | Evidence | Decision | Boundary |
|---|---|---|---|
| `{{nav}}` | `wp_nav_menu()` / menu registration | adapt + review | graph-backed nav is available; menu locations and labels need human confirmation |
| `{{breadcrumb}}` | template shell context only | review | no WordPress conditional URL semantics are inferred |
| `{{title}}` | `the_title()` | adapt | title output is a direct content mapping |
| `{{content}}` | `the_content()` | adapt | loop context becomes one Boris page |
| `{{children}}` | `wp_list_pages()` | review | only use after parent/child graph review |
| Aside | sidebar/widget output | review | Aside is inline content, not a widget runtime |
| `{{toc}}` | no stable TOC hook found | review | use Boris heading outline only after content review |
| `{{footer}}` | `footer.php` / `wp_footer()` | adapt + review | static shell maps; callback output remains manual |

## Dynamic findings

- `comments.php:1` **comments_open** — `review`; evidence: `<?php if ( comments_open() ) : ?>`
- `comments.php:1` **php_code** — `review`; evidence: `<?php if ( comments_open() ) : ?>`
- `comments.php:3` **wp_list_comments** — `review`; evidence: `  <?php wp_list_comments(); ?>`
- `comments.php:3` **php_code** — `review`; evidence: `  <?php wp_list_comments(); ?>`
- `comments.php:4` **comment_form** — `drop`; evidence: `  <?php comment_form(); ?>`
- `comments.php:4` **php_code** — `review`; evidence: `  <?php comment_form(); ?>`
- `comments.php:6` **php_code** — `review`; evidence: `<?php endif; ?>`
- `footer.php:2` **php_code** — `review`; evidence: `  <p><?php bloginfo( 'name' ); ?> · <a href="<?php echo esc_url( home_url( '/' ) ); ?>">Home</a></p>`
- `footer.php:2` **bloginfo** — `review`; evidence: `  <p><?php bloginfo( 'name' ); ?> · <a href="<?php echo esc_url( home_url( '/' ) ); ?>">Home</a></p>`
- `footer.php:4` **wp_footer** — `review`; evidence: `<?php wp_footer(); ?>`
- `footer.php:4` **php_code** — `review`; evidence: `<?php wp_footer(); ?>`
- `functions.php:4` **register_nav_menus:primary,footer** — `review`; evidence: `  register_nav_menus( array( 'primary' => 'Primary Menu', 'footer' => 'Footer Menu' ) );`
- `functions.php:6` **add_action:after_setup_theme** — `review`; evidence: `add_action( 'after_setup_theme', 'mini_kubrick_setup' );`
- `functions.php:9` **register_sidebar:primary** — `review`; evidence: `  register_sidebar( array( 'name' => 'Primary Sidebar', 'id' => 'primary' ) );`
- `functions.php:10` **register_sidebar:footer** — `review`; evidence: `  register_sidebar( array( 'name' => 'Footer Sidebar', 'id' => 'footer' ) );`
- `functions.php:12` **add_action:widgets_init** — `review`; evidence: `add_action( 'widgets_init', 'mini_kubrick_widgets' );`
- `functions.php:15` **get_stylesheet_uri** — `adapt`; evidence: `  wp_enqueue_style( 'mini-kubrick', get_stylesheet_uri() );`
- `functions.php:15` **wp_enqueue_style** — `adapt`; evidence: `  wp_enqueue_style( 'mini-kubrick', get_stylesheet_uri() );`
- `functions.php:16` **get_template_directory_uri** — `review`; evidence: `  wp_enqueue_script( 'mini-menu', get_template_directory_uri() . '/js/menu.js', array(), '1.0', true );`
- `functions.php:16` **wp_enqueue_script** — `drop`; evidence: `  wp_enqueue_script( 'mini-menu', get_template_directory_uri() . '/js/menu.js', array(), '1.0', true );`
- `functions.php:18` **add_action:wp_enqueue_scripts** — `review`; evidence: `add_action( 'wp_enqueue_scripts', 'mini_kubrick_assets' );`
- `functions.php:19` **add_filter:the_content** — `review`; evidence: `add_filter( 'the_content', 'mini_kubrick_content_filter' );`
- `header.php:2` **php_code** — `review`; evidence: `<html <?php language_attributes(); ?>>`
- `header.php:2` **language_attributes** — `review`; evidence: `<html <?php language_attributes(); ?>>`
- `header.php:4` **php_code** — `review`; evidence: `  <meta charset="<?php bloginfo( 'charset' ); ?>">`
- `header.php:4` **bloginfo** — `review`; evidence: `  <meta charset="<?php bloginfo( 'charset' ); ?>">`
- `header.php:5` **wp_title** — `adapt`; evidence: `  <title><?php wp_title( '|', true, 'right' ); ?></title>`
- `header.php:5` **php_code** — `review`; evidence: `  <title><?php wp_title( '|', true, 'right' ); ?></title>`
- `header.php:6` **wp_head** — `review`; evidence: `  <?php wp_head(); ?>`
- `header.php:6` **php_code** — `review`; evidence: `  <?php wp_head(); ?>`
- `header.php:8` **php_code** — `review`; evidence: `<body <?php body_class(); ?>>`
- `header.php:8` **body_class** — `review`; evidence: `<body <?php body_class(); ?>>`
- `header.php:10` **php_code** — `review`; evidence: `  <a class="site-title" href="<?php echo esc_url( home_url( '/' ) ); ?>"><?php bloginfo( 'name' ); ?></a>`
- `header.php:10` **bloginfo** — `review`; evidence: `  <a class="site-title" href="<?php echo esc_url( home_url( '/' ) ); ?>"><?php bloginfo( 'name' ); ?></a>`
- `header.php:11` **wp_nav_menu:primary** — `adapt`; evidence: `  <?php wp_nav_menu( array( 'theme_location' => 'primary' ) ); ?>`
- `header.php:11` **php_code** — `review`; evidence: `  <?php wp_nav_menu( array( 'theme_location' => 'primary' ) ); ?>`
- `index.php:1` **php_code** — `review`; evidence: `<?php get_header(); ?>`
- `index.php:1` **get_header** — `adapt`; evidence: `<?php get_header(); ?>`
- `index.php:3` **have_posts** — `adapt`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `index.php:3` **the_post** — `adapt`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `index.php:3` **php_code** — `review`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `index.php:4` **php_code** — `review`; evidence: `  <article id="post-<?php the_ID(); ?>" <?php post_class(); ?>>`
- `index.php:4` **post_class** — `review`; evidence: `  <article id="post-<?php the_ID(); ?>" <?php post_class(); ?>>`
- `index.php:4` **the_ID** — `review`; evidence: `  <article id="post-<?php the_ID(); ?>" <?php post_class(); ?>>`
- `index.php:5` **the_title** — `adapt`; evidence: `    <h1><?php the_title(); ?></h1>`
- `index.php:5` **php_code** — `review`; evidence: `    <h1><?php the_title(); ?></h1>`
- `index.php:6` **the_content** — `adapt`; evidence: `    <div class="entry-content"><?php the_content(); ?></div>`
- `index.php:6` **php_code** — `review`; evidence: `    <div class="entry-content"><?php the_content(); ?></div>`
- `index.php:8` **php_code** — `review`; evidence: `<?php endwhile; endif; ?>`
- `index.php:10` **php_code** — `review`; evidence: `<?php get_sidebar(); ?>`
- `index.php:10` **get_sidebar** — `review`; evidence: `<?php get_sidebar(); ?>`
- `index.php:11` **php_code** — `review`; evidence: `<?php get_footer(); ?>`
- `index.php:11` **get_footer** — `adapt`; evidence: `<?php get_footer(); ?>`
- `page.php:1` **php_code** — `review`; evidence: `<?php get_header(); ?>`
- `page.php:1` **get_header** — `adapt`; evidence: `<?php get_header(); ?>`
- `page.php:3` **have_posts** — `adapt`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `page.php:3` **the_post** — `adapt`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `page.php:3` **php_code** — `review`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `page.php:5` **the_title** — `adapt`; evidence: `    <h1><?php the_title(); ?></h1>`
- `page.php:5` **php_code** — `review`; evidence: `    <h1><?php the_title(); ?></h1>`
- `page.php:6` **the_content** — `adapt`; evidence: `    <?php the_content(); ?>`
- `page.php:6` **php_code** — `review`; evidence: `    <?php the_content(); ?>`
- `page.php:8` **php_code** — `review`; evidence: `<?php endwhile; endif; ?>`
- `page.php:10` **php_code** — `review`; evidence: `<?php get_footer(); ?>`
- `page.php:10` **get_footer** — `adapt`; evidence: `<?php get_footer(); ?>`
- `searchform.php:1` **php_code** — `review`; evidence: `<form role="search" method="get" class="search-form" action="<?php echo esc_url( home_url( '/' ) ); ?>">`
- `searchform.php:3` **get_search_query** — `drop`; evidence: `    <input type="search" name="s" value="<?php echo esc_attr( get_search_query() ); ?>">`
- `searchform.php:3` **php_code** — `review`; evidence: `    <input type="search" name="s" value="<?php echo esc_attr( get_search_query() ); ?>">`
- `sidebar.php:2` **php_code** — `review`; evidence: `  <?php if ( is_active_sidebar( 'primary' ) ) : ?>`
- `sidebar.php:2` **is_active_sidebar:primary** — `review`; evidence: `  <?php if ( is_active_sidebar( 'primary' ) ) : ?>`
- `sidebar.php:3` **php_code** — `review`; evidence: `    <?php dynamic_sidebar( 'primary' ); ?>`
- `sidebar.php:3` **dynamic_sidebar:primary** — `review`; evidence: `    <?php dynamic_sidebar( 'primary' ); ?>`
- `sidebar.php:4` **php_code** — `review`; evidence: `  <?php endif; ?>`
- `sidebar.php:6` **wp_list_pages** — `adapt`; evidence: `    <?php wp_list_pages( array( 'title_li' => '' ) ); ?>`
- `sidebar.php:6` **php_code** — `review`; evidence: `    <?php wp_list_pages( array( 'title_li' => '' ) ); ?>`
- `sidebar.php:8` **php_code** — `review`; evidence: `  <?php get_search_form(); ?>`
- `sidebar.php:8` **get_search_form** — `review`; evidence: `  <?php get_search_form(); ?>`
- `single.php:1` **php_code** — `review`; evidence: `<?php get_header(); ?>`
- `single.php:1` **get_header** — `adapt`; evidence: `<?php get_header(); ?>`
- `single.php:3` **have_posts** — `adapt`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `single.php:3` **the_post** — `adapt`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `single.php:3` **php_code** — `review`; evidence: `<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>`
- `single.php:5` **the_title** — `adapt`; evidence: `    <h1><?php the_title(); ?></h1>`
- `single.php:5` **php_code** — `review`; evidence: `    <h1><?php the_title(); ?></h1>`
- `single.php:6` **php_code** — `review`; evidence: `    <p class="entry-meta"><?php the_author(); ?> · <?php the_date(); ?></p>`
- `single.php:6` **the_author** — `review`; evidence: `    <p class="entry-meta"><?php the_author(); ?> · <?php the_date(); ?></p>`
- `single.php:6` **the_date** — `review`; evidence: `    <p class="entry-meta"><?php the_author(); ?> · <?php the_date(); ?></p>`
- `single.php:7` **the_content** — `adapt`; evidence: `    <?php the_content(); ?>`
- `single.php:7` **php_code** — `review`; evidence: `    <?php the_content(); ?>`
- `single.php:9` **comments_template** — `review`; evidence: `  <?php comments_template(); ?>`
- `single.php:9` **php_code** — `review`; evidence: `  <?php comments_template(); ?>`
- `single.php:10` **php_code** — `review`; evidence: `<?php endwhile; endif; ?>`
- `single.php:12` **php_code** — `review`; evidence: `<?php get_footer(); ?>`
- `single.php:12` **get_footer** — `adapt`; evidence: `<?php get_footer(); ?>`
- `style.css:2` **Theme Name** — `preserve`; evidence: `Theme Name: Mini Kubrick Benchmark`
- `style.css:3` **Theme URI** — `preserve`; evidence: `Theme URI: https://example.invalid/mini-kubrick`
- `style.css:4` **Author** — `preserve`; evidence: `Author: Boris migration lab`
- `style.css:5` **Version** — `preserve`; evidence: `Version: 1.0.0`
- `style.css:6` **Template** — `preserve`; evidence: `Template: classic`

## Artifacts

- `inventory.json` — sorted file and signal inventory
- `slot_mapping.json` — closed Boris slot proposal
- `manual_review.json` — all unsupported/dynamic evidence with source lines
- `prototype/main.html` — static no-runtime prototype
- `report.json` — counts and policy

Decisions use `preserve` for static bytes/provenance, `adapt` for a closed slot mapping, `review` for ambiguous or runtime-backed behavior, and `drop` for refused runtime-only behavior.
