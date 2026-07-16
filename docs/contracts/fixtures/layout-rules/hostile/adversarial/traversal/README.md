# Layout path traversal / escape probes

Hostile layout path strings used by the Zig harness (not product sources):

| Path shape | Intent |
|------------|--------|
| `../layouts/main.html` | parent-segment escape |
| `themes/alpha/layouts/../../themes/beta/layouts/main.html` | cross-theme via `..` |
| `/tmp/escape.html` | absolute path |
| `themes/alpha/layouts/main.html/../main.html` | odd trailing form |

Contract expectation: managed theme roots stay single-root per target;
path escapes must not silently publish. Exact error class may be
`MixedThemeRoots`, load/I/O failure, or path validation — harness records the
observed classification without weakening the product.
