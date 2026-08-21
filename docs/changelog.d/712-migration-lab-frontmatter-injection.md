### Security

- Neutralize YAML injection in migration-lab generated frontmatter: WordPress tags/preserved titles and Starlight/Filed titles are now quoted/escaped, and control characters are dropped, so hostile taxonomy names or `": "` titles can no longer inject keys or emit invalid YAML. See [`tools/migration-lab/wordpress.zig`](/tools/migration-lab/wordpress.zig) and [#712](https://github.com/drawmeanelephant/boris/issues/712).
