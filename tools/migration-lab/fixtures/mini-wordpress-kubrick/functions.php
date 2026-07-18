<?php
function mini_kubrick_setup() {
  add_theme_support( 'automatic-feed-links' );
  register_nav_menus( array( 'primary' => 'Primary Menu', 'footer' => 'Footer Menu' ) );
}
add_action( 'after_setup_theme', 'mini_kubrick_setup' );

function mini_kubrick_widgets() {
  register_sidebar( array( 'name' => 'Primary Sidebar', 'id' => 'primary' ) );
  register_sidebar( array( 'name' => 'Footer Sidebar', 'id' => 'footer' ) );
}
add_action( 'widgets_init', 'mini_kubrick_widgets' );

function mini_kubrick_assets() {
  wp_enqueue_style( 'mini-kubrick', get_stylesheet_uri() );
  wp_enqueue_script( 'mini-menu', get_template_directory_uri() . '/js/menu.js', array(), '1.0', true );
}
add_action( 'wp_enqueue_scripts', 'mini_kubrick_assets' );
add_filter( 'the_content', 'mini_kubrick_content_filter' );
