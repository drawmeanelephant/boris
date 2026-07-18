<aside id="sidebar" class="widget-area">
  <?php if ( is_active_sidebar( 'primary' ) ) : ?>
    <?php dynamic_sidebar( 'primary' ); ?>
  <?php endif; ?>
  <nav class="page-list">
    <?php wp_list_pages( array( 'title_li' => '' ) ); ?>
  </nav>
  <?php get_search_form(); ?>
</aside>
