# GitHub Pages publication

Boris includes an official GitHub Actions workflow at
`.github/workflows/github-pages.yml`. It builds the repository’s documentation
with the native Boris binary, resolves the Pages location through
`actions/configure-pages`, validates that location in a Boris publication
profile, and deploys only the verified public site tree.

## Enable the target

In the repository’s **Settings → Pages**, choose **GitHub Actions** as the
source. The workflow runs for pushes to `main` and can also be started with
**Run workflow**. The workflow uses the supported Pages action sequence:

1. `actions/checkout@v6`
2. `actions/configure-pages@v5`
3. `actions/upload-pages-artifact@v4`
4. `actions/deploy-pages@v4`

It grants `contents: read` to the build, `pages: write` to the Pages artifact
and deployment jobs, and `id-token: write` only to the deployment job. Build
and deployment concurrency is serialized so an older run cannot cancel a
newer deployment halfway through.

## Location model

GitHub supplies three related values to the workflow: `base_url`, `origin`, and
`base_path`. Boris records them in the temporary profile used by
`boris plan --profile` and rejects contradictions before the site build:

| Pages shape | Example `base_url` | `origin` | `base_path` |
|---|---|---|---|
| Project site | `https://owner.github.io/boris` | `https://owner.github.io` | `/boris` |
| User/org root site | `https://owner.github.io` | `https://owner.github.io` | empty |
| Custom domain | `https://docs.example.com` | `https://docs.example.com` | empty |

The current declaration slice does not invent a CNAME or probe the network.
If a custom domain is configured with a non-empty path, or if `base_url` does
not equal `origin + base_path`, the profile fails closed. The normalized
identity is also available in the [publication profile](contracts/publication-profile.md)
and [publication plan](contracts/publication-plan.md) contracts.

The build step consumes that normalized plan identity directly:

```text
boris --target public=dist --sitemap \
  --pages-base-url https://owner.github.io/boris \
  --pages-origin https://owner.github.io \
  --pages-base-path /boris \
  --site-url https://owner.github.io/boris
```

The compiler audits rendered root-relative/public metadata URLs before target
replacement and binds sitemap URLs to the same identity. `EPUBLICATIONLOCATION`
is an actionable publication failure. Root and custom-domain builds pass an
explicit empty `--pages-base-path`. The check is against the local generated
artifact; this workflow still makes no post-deploy HTTP claim.

## Public artifact and retained evidence

The workflow creates two deliberately different uploads:

- The Pages artifact is copied from the exact `committed` records in
  `dist/_boris/proof/artifacts.json`. The copier checks every byte count and
  SHA-256, requires `index.html`, rejects symlinks and hard links, enforces the
  supported 1 GiB Pages artifact limit, and excludes `_boris/proof` reports.
- The retained evidence artifact contains the normalized plan, the target-local
  proof reports, and `github-pages-evidence.json`. That binding records the
  source commit, Boris/Apex pins, workflow identity, inventory digest, public
  file count/bytes, and the exact public-tree manifest digest.

The build summary reports the target, resolved URL/path, public payload size,
inventory binding, compiler finding count, and the explicit limitation that
deployment verification and a post-deploy HTTP audit are not claimed by this
workflow. A successful `deploy-pages` job means GitHub accepted the Pages
artifact for deployment; it is not a Boris claim that every URL projection or
browser request was audited.

For GitHub’s workflow requirements and action behavior, see the
[custom workflows for GitHub Pages](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages),
[`configure-pages`](https://github.com/actions/configure-pages),
[`upload-pages-artifact`](https://github.com/actions/upload-pages-artifact), and
[`deploy-pages`](https://github.com/actions/deploy-pages) documentation.
