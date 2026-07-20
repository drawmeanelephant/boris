# ApexMarkdown Unified compatibility fixture

**Read-only audit** of Apex Unified features as exercised through Boris
(HTML path, host adapter `vendor/apex/apex.c`, pin ApexMarkdown **v1.1.12**).

Normative product ABI boundary: [`../../apex-abi.md`](../../apex-abi.md).  
Upstream feature inventory: [`../../../../vendor/apex-markdown/pages/index.md`](../../../../vendor/apex-markdown/pages/index.md).

| File | Role |
|------|------|
| [`MATRIX.md`](MATRIX.md) | Compatibility matrix (classifications) |
| [`REPORT.md`](REPORT.md) | Method, evidence, gate commands, findings |
| `content/` | Trunk/Satellite site exercising feature families |
| `theme/layouts/main.html` | Minimal layout (`{{content}}` only) |
| `assets/pixel.png` | 1×1 PNG for image probes |

## Classifications

1. **supported and tested** — works on the Boris HTML path and is covered by
   `src/apex.zig` fidelity tests and/or this fixture’s observed HTML markers
2. **supported but unverified** — host/engine defaults imply support; no
   durable automated pin or incomplete probe
3. **intentionally disabled/non-goal** — host adapter, AGENTS constraints, or
   product closed frontmatter keep the feature off
4. **broken or behaviorally surprising** — renders, but diverges from Apex
   docs or from reasonable author expectations

This tree does **not** change product code. Do not treat unexpected rows as
permission to “fix” Apex or the host adapter without a separate decision.

## Compile (from repo root)

```bash
zig build

./zig-out/bin/boris \
  --input docs/contracts/fixtures/apex-unified-compat/content \
  --theme docs/contracts/fixtures/apex-unified-compat/theme \
  --html-dir test-output/apex-unified-compat \
  --quiet

echo $?   # expect 0
ls test-output/apex-unified-compat/features/
```

Keep outputs under `test-output/` (gitignored). Do not commit generated HTML.

## Related automated coverage

```bash
zig build test                 # includes apex.zig U1–U18 fidelity
zig build test-apex-hostile    # host ABI status-first hostile engine
```
