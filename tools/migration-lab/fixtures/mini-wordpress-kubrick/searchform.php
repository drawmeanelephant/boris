<form role="search" method="get" class="search-form" action="<?php echo esc_url( home_url( '/' ) ); ?>">
  <label><span class="screen-reader-text">Search</span>
    <input type="search" name="s" value="<?php echo esc_attr( get_search_query() ); ?>">
  </label>
  <button type="submit">Search</button>
</form>
