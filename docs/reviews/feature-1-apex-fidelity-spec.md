# Feature 1 — Apex fidelity (handoff pointer)

**Status:** **Feature 1 product Done** (Chats 1–5); optional Chats 6–7 review  
**Date:** 2026-07-14 (pointer); implemented 2026-07-15

## Authority

**Implementation plan:**

[`APEX-Feature1-plan.md`](../../APEX-Feature1-plan.md) (repository root)

**Do not** implement “replace Apex with cmark-gfm.” That was a mistaken draft.

**Correct goal:** vendor and link **[ApexMarkdown/apex](https://github.com/ApexMarkdown/apex)**
and call it from Boris’s host `apex_render` adapter in **`APEX_MODE_UNIFIED`**
(default). See [Modes](https://github.com/ApexMarkdown/apex/wiki/Modes) and
[C API](https://github.com/ApexMarkdown/apex/wiki/C-API).

**Product land (Chat 1–5 done):**

[`vendor/apex-markdown/VENDOR.md`](../../vendor/apex-markdown/VENDOR.md) — v1.1.11;
static link; Unified adapter; U1–U17; docs/STATUS Done. Optional: internal review
(`docs/reviews/feature-1-internal-review.md`) and external audit response.

**ABI contract (Boris host lifetime rules still win):**

[`docs/contracts/apex-abi.md`](../contracts/apex-abi.md)

## Prompt seed

See `APEX-Feature1-plan.md` §11.
