# Layout path traversal / escape probes

Hostile layout path strings rejected **lexically** at CLI parse / target
validation / compile preflight (`layout_select.validateLayoutPath`):

| Path shape | Intent | Expect |
|------------|--------|--------|
| `../layouts/main.html` | parent-segment escape | exit 2 / `InvalidLayoutPath` |
| `themes/alpha/layouts/../../themes/beta/layouts/main.html` | cross-theme via `..` | exit 2 / `InvalidLayoutPath` |
| `/tmp/escape.html` | absolute path | exit 2 / `InvalidLayoutPath` |
| `theme/./layouts/main.html` | `.` segment | exit 2 / `InvalidLayoutPath` |
| `layouts\main.html` | backslash separator | exit 2 / `InvalidLayoutPath` |

No discovery, selection, or HTML publish after these paths.
