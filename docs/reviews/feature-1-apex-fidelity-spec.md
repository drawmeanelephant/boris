# Feature 1 — Apex fidelity (handoff pointer)

**Status:** corrected target — real ApexMarkdown Unified; **Chat 1 pin landed**  
**Date:** 2026-07-14 (pointer); pin 2026-07-15

## Authority

**Implementation plan:**

[`APEX-Feature1-plan.md`](../../APEX-Feature1-plan.md) (repository root)

**Do not** implement “replace Apex with cmark-gfm.” That was a mistaken draft.

**Correct goal:** vendor and link **[ApexMarkdown/apex](https://github.com/ApexMarkdown/apex)**
and call it from Boris’s host `apex_render` adapter in **`APEX_MODE_UNIFIED`**
(default). See [Modes](https://github.com/ApexMarkdown/apex/wiki/Modes) and
[C API](https://github.com/ApexMarkdown/apex/wiki/C-API).

**Pin + link + adapter + fidelity (Chat 1–4 done):**

[`vendor/apex-markdown/VENDOR.md`](../../vendor/apex-markdown/VENDOR.md) — v1.1.11 snapshot;
static link; Unified adapter; U1–U17 structural tests. Next is Chat 5 (docs/STATUS Done +
release-gate).

**ABI contract (Boris host lifetime rules still win):**

[`docs/contracts/apex-abi.md`](../contracts/apex-abi.md)

## Prompt seed

See `APEX-Feature1-plan.md` §11.
