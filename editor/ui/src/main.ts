import { mount } from 'svelte';
import App from './App.svelte';
import { initTheme } from './lib/theme.svelte';
import './styles.css';

// Resolve the theme before mount so the first paint carries the right palette.
initTheme();
mount(App, { target: document.getElementById('app')! });
