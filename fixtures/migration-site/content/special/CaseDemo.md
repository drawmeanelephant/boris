---
title: Case-sensitive ID demo
status: published
tags: [special, identity]
---

# CaseDemo

This file path is `special/CaseDemo.md`. The entity id is therefore:

```text
special/CaseDemo
```

## Why a Trunk?

Standalone demos stay **Trunks** so they appear at the forest root without
forcing a parent section. Production content usually nests under section
Trunks instead.

## Linking rules

Correct:

```markdown
[[special/CaseDemo]]
[[special/CaseDemo|Case demo]]
```

Incorrect (fails with `EREFERENCEMISSING` if nothing else defines that id):

```markdown
[[special/casedemo]]
[[special/caseDemo]]
```

## Related

[[concepts/path-identity]] · [[reference/entity-ids]] · [[special/cafe-notes]]
