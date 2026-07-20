# Boris benchmark report

This is an opt-in synthetic cold-build benchmark, not a compiler behavior or CI gate. Each sample deletes the prior output tree first; `cleanup_ms` is measured separately, and `compile_ms` begins after that deletion completes.

## Environment

| Field | Value |
|---|---|
| OS | macos |
| CPU model | unavailable |
| CPU cores | 10 |
| Zig version | 0.16.0 |
| Optimization mode | Debug |
| Input bytes | 23381 |
| Requested runs per worker setting | 3 |

The output digest is SHA-256 over sorted relative output paths, each path length, path bytes, file length, and file bytes. Equal digests and byte counts across runs are the determinism check. Peak RSS is reported in the host `/usr/bin/time` unit when that wrapper is available.

## Samples

| Workers | Run | Cleanup (ms) | Compile (ms) | Output bytes | Output SHA-256 | Peak RSS |
|---:|---:|---:|---:|---:|---|---|
| 1 | 1 | 0.021 | 544.375 | 942537 | `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a` | unavailable |
| 1 | 2 | 3.318 | 534.846 | 942537 | `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a` | unavailable |
| 1 | 3 | 3.567 | 579.094 | 942537 | `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a` | unavailable |
| 8 | 1 | 4.267 | 528.476 | 942537 | `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a` | unavailable |
| 8 | 2 | 3.881 | 534.240 | 942537 | `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a` | unavailable |
| 8 | 3 | 3.886 | 532.954 | 942537 | `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a` | unavailable |

## Arithmetic and interpretation

- **-j1:** arithmetic mean cleanup `2.302 ms`, arithmetic mean compile `552.772 ms` over 3 samples; digest `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a`; deterministic: **yes**.
- **-j8:** arithmetic mean cleanup `4.011 ms`, arithmetic mean compile `531.890 ms` over 3 samples; digest `e5257fd97e48fb3704b7819871124e439225a7c7301538e3d0bd91bdccdb7f9a`; deterministic: **yes**.

Worker comparisons are valid only within this report. Comparisons across machines are **non-comparable unless OS, CPU model, core count, Zig version, optimization mode, input bytes, and worker settings match**; elapsed time and RSS are environment observations, not portable performance claims.
