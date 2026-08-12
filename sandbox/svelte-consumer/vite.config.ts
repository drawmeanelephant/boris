import adapter from '@sveltejs/adapter-static';
import { sveltekit } from '@sveltejs/kit/vite';
import { defineConfig } from 'vite';

export default defineConfig({
	plugins: [
		sveltekit({
			compilerOptions: {
				// Force runes mode for the project, except for libraries. Can be removed in svelte 6.
				runes: ({ filename }) =>
					filename.split(/[/\\]/).includes('node_modules') ? undefined : true
			},

			// This sandbox is a pure static consumer: Boris output in, static site
			// out. No server at runtime. All routes are prerendered at build time
			// from data/ (Boris IR + body fragments).
			adapter: adapter(),

			prerender: {
				// Crawl from the index page; every entity linked there gets a
				// prerendered detail route. If any internal link is broken, the
				// build fails loudly (complements Boris's own graph validation).
				entries: ['*']
			}
		})
	]
});
