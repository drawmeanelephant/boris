# Archive — not the living product docs

**Purpose:** hold campaign notes, self-audits, and review writeups that were
useful during ship but are **not** the default context for day-to-day work.

This folder is a **staging box**. It may leave the repo entirely (move off-tree
or delete) without changing compiler behavior. Prefer:

| Live (keep in-tree) | Archive (here) |
|---------------------|----------------|
| `README.md` | Feature 1 campaign reviews |
| `docs/STATUS.md` | P3.3 / post-P3 reconciliation writeups |
| `docs/contracts/**` | m10 `AUDIT-v0.1.md` |
| `docs/RELEASE-GATE.md` | |
| `docs/rag/system/**` | |
| `CHANGELOG.md` | |
| `AGENTS.md` | |

## Contents

```text
archive/docs/
  AUDIT-v0.1.md                 # historical m10 self-audit
  reviews/
    feature-1-*.md              # Apex fidelity campaign + reviews
    p3.3-multi-target-review.md
    post-p3-reconciliation.md
```

## Rules

1. **Do not treat archive prose as normative.** Contracts under
   `docs/contracts/` win on conflict.
2. **Do not cite archive paths in new STATUS/README “start here” lists.**
   Historical `CHANGELOG` bullets may still point here.
3. Safe to remove from a working clone if you need a thinner tree; git history
   retains the files.

Moved out of `docs/` during the post–Feature 2 docs hygiene pass so agent and
human context stays on the current product surface.
