<?php get_header(); ?>
<main id="content" class="site-content page-template">
<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>
  <article class="entry entry-page">
    <h1><?php the_title(); ?></h1>
    <?php the_content(); ?>
  </article>
<?php endwhile; endif; ?>
</main>
<?php get_footer(); ?>
