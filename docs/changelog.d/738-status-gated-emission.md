# 738 status-gated emission

## Changed

- `status: draft` pages on the default HTML target are now emitted but no
  longer advertised: `{{nav}}` prunes draft-rooted subtrees, `{{children}}`
  omits draft children, and the site-nav fingerprint material includes
  status so incremental rebuilds stay correct. Drafts keep rendering at
  their routes so links resolve; `archived` stays advertised. See
  [the HTML output contract](/docs/contracts/html-output.md).
