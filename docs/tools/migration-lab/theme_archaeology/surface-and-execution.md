---
title: "`tools/migration-lab/theme_archaeology.zig` surface and execution"
id: docs/tools/migration-lab/theme_archaeology/surface-and-execution
parent: docs/tools/migration-lab/theme_archaeology
status: draft
tags: [boris, zig, tools, surface, migration-lab, theme_archaeology]
---

# `tools/migration-lab/theme_archaeology.zig` surface and execution

## CLI surface

The `theme_archaeology.zig` module has no CLI parser of its own. All CLI handling is in `main.zig`. The relevant flags for this mode are:


| Argument or flag | Required | Default | Accepted values | Effect | Failure behavior |
| :-- | :-- | :-- | :-- | :-- | :-- |
| `--mode theme-archaeology` | No (but needed to select mode) | `astro` | `theme-archaeology`, `theme`, `theme-arch`, `theme-inventory` | Selects this module | `error.InvalidValue` → exit 2 |
| `--root &lt;DIR>` | Yes (effectively) | `.` | Any directory path | Sets `Options.rootdir`; the scan root | Proceeds with `.` if omitted; `SourceNotFound` if not openable |
| `--out &lt;DIR>` | No | `migration-report` | Any directory path | Sets `Options.outdir`; must differ from `--root` | Exit 2 with message if equal to `--root` |
| `-q` / `--quiet` | No | off | flag | Suppresses progress line | n/a |
| `-h` / `--help` | No | off | flag | Prints usage, exits 0 | n/a |

Exit codes: 0 success, 2 usage error, 3 I/O or lab error. Exact exit codes for specific I/O failures within the module (e.g., unreadable scan root) propagate as `error.IoFailure` or `error.SourceNotFound`, which `main.zig` maps to exit code 3.[^1_1][^1_3]

## Inputs and discovery model

The module walks the scan root recurs
<span style="display:none">[^1_5][^1_6][^1_7]</span>

<div align="center">⁂</div>

[^1_1]: boris-source-2.md

[^1_2]: INDEX.md

[^1_3]: boris-source-1.md

[^1_4]: boris-source-3.md

[^1_5]: boris-source-4.md

[^1_6]: boris-docs.md

[^1_7]: boris-content.md
