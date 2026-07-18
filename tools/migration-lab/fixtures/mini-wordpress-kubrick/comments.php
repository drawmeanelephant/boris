<?php if ( comments_open() ) : ?>
<section id="comments" class="comments">
  <?php wp_list_comments(); ?>
  <?php comment_form(); ?>
</section>
<?php endif; ?>
