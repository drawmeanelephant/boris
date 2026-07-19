---
title: How Boris was built
parent: contest
status: published
tags: [build-week, codex, process]
---

# How Boris was built

Boris began as a human question—could a small native compiler make
documentation structure trustworthy without inheriting a JavaScript site stack?
GPT-5.6 helped turn that question into an initial scaffold; Codex then remained
in the loop through architecture, implementation, test design, release work,
and the stubborn business of finding claims that were too broad.

## Human steering stayed in the critical path

The collaboration was not “ask for an app, accept the first app.” The human
side selected Zig and the in-process Apex boundary, set the closed author
grammar, kept executable MDX out of scope, chose which migrations mattered,
reviewed PRs, and repeatedly cut work that did not earn its complexity.

The AI side accelerated implementation and investigation: code paths, fixtures,
hostile tests, documentation reconciliation, migration audits, and release
gates. When a test or audit found a problem, the claim changed or the code did.

## A record instead of mythology

The [[agents|Agent Field Notes]] are content dogfood and a thank-you record.
They deliberately distinguish:

- named Codex workers with a concrete merged contribution;
- investigation/support lanes where the repository cannot prove individual
  authorship; and
- external tools such as [[agents/grok|Grok]] and
  [[agents/antigravity|Antigravity]], which are not recast as Codex workers.

That restraint is part of the project’s point. The story should be interesting,
but it should still survive a checkout of the repository.

## What the process taught us

1. A passing happy path is not proof of a migration boundary.
2. A skipped tool is not a passing tool.
3. A generated asset is only useful when it survives a real compile.
4. A small, truthful capability is worth more than a universal-importer claim.

For one compact task-level example, see
[[agents/codex-session-success-story|the Codex session success story]]. For the
reviewer’s version of the same ethic, see [[agents/bacon|Bacon]].
