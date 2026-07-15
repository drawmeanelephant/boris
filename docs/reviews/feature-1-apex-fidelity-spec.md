# Feature 1 — Apex fidelity (handoff pointer)

**Status:** corrected target — real ApexMarkdown Unified  
**Date:** 2026-07-14

## Authority

**Implementation plan:**

[`APEX-Feature1-plan.md`](../../APEX-Feature1-plan.md) (repository root)

**Do not** implement “replace Apex with cmark-gfm.” That was a mistaken draft.

**Correct goal:** vendor and link **[ApexMarkdown/apex](https://github.com/ApexMarkdown/apex)**
and call it from Boris’s host `apex_render` adapter in **`APEX_MODE_UNIFIED`**
(default). See [Modes](https://github.com/ApexMarkdown/apex/wiki/Modes) and
[C API](https://github.com/ApexMarkdown/apex/wiki/C-API).

**ABI contract (Boris host lifetime rules still win):**

[`docs/contracts/apex-abi.md`](../contracts/apex-abi.md)

## Prompt seed

See `APEX-Feature1-plan.md` §11.
