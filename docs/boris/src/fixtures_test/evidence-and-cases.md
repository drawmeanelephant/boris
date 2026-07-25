---
title: "`src/fixtures_test.zig` evidence and cases"
id: docs/boris/src/fixtures_test/evidence-and-cases
parent: docs/boris/src/fixtures_test
status: draft
tags: [boris, zig, source-reference, evidence, fixtures_test]
---

# `src/fixtures_test.zig` evidence and cases

## Behavioral invariants (directly demonstrated by tests)

1. **`fixtures/` is openable and carries core inventory files**
After `openFixtures`, `manifest.json`, `README.md`, and `expected/invalid-categories.txt` all exist under that directory.[^3_1]
2. **Every `manifest.json` → `valid[]` path exists on disk**
Parsed JSON object field `valid` is an array of objects each with `path`; each path exists under `fixtures/`. The test also asserts `valid.items.len == 4`.[^3_1]
3. **Invalid suite: one path per entry, categories cover required set**
    - `invalid` array length equals `required_categories.len` (8).
    - Each invalid item has `expectedCategory` and `paths` with `paths.len == 1`, and each path exists.
    - Every string in manifest `requiredInvalidCategories` appears among seen `expectedCategory` values.
    - Every hard-coded `required_categories` code also appears among seen categories.[^3_1]
4. **`expected/invalid-categories.txt` matches the required set**
Non-empty, non-`#`-comment lines form a set equal in size to `required_categories.len`, and every required code is present.[^3_1]
5. **`content/invalid/invalid-utf8.md` is non-empty and not valid UTF-8**
`raw.len > 0` and `!std.unicode.utf8ValidateSlice(raw)`.[^3_1]
6. **`content/valid/empty-no-fm.md` is empty (zero bytes)**
Contract note in-test: empty page with no frontmatter is allowed; `raw.len == 0`.[^3_1]

***

## Inline tests

| Test name | Kind | Purpose | Key assertion |
| :-- | :-- | :-- | :-- |
| `fixtures root directory is openable` | Presence | Root dir + core files | `manifest.json`, `README.md`, `expected/invalid-categories.txt` exist |
| `fixtures valid content files listed in manifest exist` | Manifest vs disk | Valid suite integrity | `valid.len == 4`; each `path` exists |
| `fixtures invalid suite files exist and categories are documented` | Manifest vs disk + categories | Invalid suite + dual category lists | `invalid.len == 8`; one path each; `requiredInvalidCategories` ⊆ seen; `required_categories` ⊆ seen |
| `fixtures expected/invalid-categories.txt matches required set` | Text checklist | Category file vs hard-coded set | Every required code present; `found.count == 8` |
| `fixtures invalid-utf8 fixture is not valid UTF-8` | Byte property | Keep adversarial UTF-8 fixture hostile | Non-empty; `utf8ValidateSlice` false |
| `fixtures empty-no-fm is empty and has no frontmatter fence` | Byte property | Empty valid page contract | `raw.len == 0` |


***

## Control flow

```text
openFixtures(io)
    └─ cwd.openDir("fixtures")
         on error → log "run tests with cwd at package root" → return err

test "root openable"
    openFixtures → expect manifest.json, README.md, expected/invalid-categories.txt

test "valid listed exist"
    read manifest.json → parse JSON
    valid = root.valid.array
    expect len == 4
    for each item: expect pathExists(path)

test "invalid suite + categories"
    read/parse manifest
    invalid = root.invalid.array
    required = root.requiredInvalidCategories.array
    expect invalid.len == required_categories.len
    for each invalid item:
        record expectedCategory
        expect paths.len == 1
        expect each path exists
    for each requiredInvalidCategories item: expect seen
    for each required_categories code: expect seen

test "expected/invalid-categories.txt"
    read file; split lines; skip empty and '#' comments
    put each line in set
    every required_categories code ∈ set
    set.count == required_categories.len

test "invalid-utf8"
    read content/invalid/invalid-utf8.md
    expect len > 0 and not utf8ValidateSlice

test "empty-no-fm"
    read content/valid/empty-no-fm.md
    expect len == 0
```


***
