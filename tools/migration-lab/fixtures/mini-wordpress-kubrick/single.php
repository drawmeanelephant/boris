<?php get_header(); ?>
<main id="content" class="site-content">
<?php if ( have_posts() ) : while ( have_posts() ) : the_post(); ?>
  <article class="entry entry-single">
    <h1><?php the_title(); ?></h1>
    <p class="entry-meta"><?php the_author(); ?> · <?php the_date(); ?></p>
    <?php the_content(); ?>
  </article>
  <?php comments_template(); ?>
<?php endwhile; endif; ?>
</main>
<?php get_footer(); ?>
