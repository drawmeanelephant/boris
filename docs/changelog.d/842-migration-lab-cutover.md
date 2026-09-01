<!--
Filename: 834-migration-lab-cutover.md (draft; rename to the PR number when the
PR exists). Keep exactly one category heading.
-->

### Changed

- The migration laboratory moved out of this repository: `tools/migration-lab/`,
  the migration-owned contracts (`astro-import-plan`, `astro-import-apply`,
  `astro-import-plan-policy-v1`, `takeout-lab-intake` and their schemas),
  `docs/MIGRATION.md`, and the Contoso fixture now live in the
  [boris-migration-lab repository](https://github.com/drawmeanelephant/boris-migration-lab);
  this repo's pointers (README, SOURCE-MAP, the contracts index,
  AGENT-BINARY-KITS, RELEASE-GATE) link there, and its `migration-lab-test`
  CI lane was removed. The frontmatter parser remains published as a `parser`
  package module so the lab can pin it through `build.zig.zon`.