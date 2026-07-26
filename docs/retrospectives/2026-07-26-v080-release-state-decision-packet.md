# v0.8.0 release-state decision packet

**Investigation date:** 2026-07-26
**Scope:** read-only investigation from `afterparty` commit
`c87bee3cb26e7eeb1eb2487dc66a0d48bd3d2a77`. This packet neither moves a
ref nor changes a GitHub release, archive, changelog, or fragment.

## Decision required

**Fact:** the published `v0.8.0` GitHub release is attached to an annotated
tag which peels to a 0.7.0 tree. The tag commit is not an ancestor of either
current `main` or `afterparty`.

**Fact:** the intended v0.8.0 release-preparation merge is
`e65e6746abbbcf1a8859069bfa0fa3319abd6927` (PR #189). It is an ancestor of
both current branch tips and carries the v0.8.0 package/compiler metadata.

**Judgment:** because a public release record already exists, preserving the
existing tag and publishing a new corrective identifier is the least
history-rewriting recovery. A release owner must choose; this packet does not
make that choice.

## Evidence

| Item | Observed value |
|---|---|
| Annotated tag object | `a89d5f79993865acadf5b66f35b75e88b09883f4` |
| Tagger / timestamp | draw me an elephant; 2026-07-21 15:17:08 -0400 |
| Tag subject | `Boris v0.8.0` |
| Peeled tag commit | `281fc9740a3ffe50408c24227e902d3b3b651006` |
| Peeled commit subject | `bench: add reproducible Filed build harness` |
| Peeled commit metadata | `build.zig.zon` version `0.7.0`; `pipeline.compiler_id` `boris/0.7.0`; `pipeline.boris_version` `0.7.0`; base IR `0.2.0`, semantic IR `0.3.0` |
| Intended v0.8.0 merge | `e65e6746abbbcf1a8859069bfa0fa3319abd6927`, PR #189, `chore: prepare v0.8.0 release` |
| Intended merge metadata | package `0.8.0`; compiler `boris/0.8.0`; base IR `0.2.0`; semantic IR `0.3.0` |
| `afterparty` investigated | `c87bee3cb26e7eeb1eb2487dc66a0d48bd3d2a77`, PR #238 merge |
| `main` investigated | `d03ed354636de6edd6308d49487ee1155a085702` |
| `main` / `afterparty` merge base | `e65e6746abbbcf1a8859069bfa0fa3319abd6927` |
| Tag / `afterparty` merge base | `306d96dd43d5a3728ac812aaeff14dbe4a55e4f2` |
| Tag ancestry | tag commit is ancestor of neither `main` nor `afterparty`; `e65e6746` is ancestor of both |

The GitHub API reports a **published, non-draft, non-prerelease** release
named `Boris v0.8.0`, published 2026-07-21T19:17:15Z, with
`target_commitish: main` and tag `v0.8.0`. It has **no uploaded release
assets**. This proves a public release record refers to the bad tag; it does
not establish that users downloaded the automatically generated source archive
or built from it.

No tracked `packages/` archive exists at `afterparty`. The release gate's
package review creates only a temporary archive under `.release-gate/` and
cleans it on exit; no package artifact was created or retained by this
investigation.

## What the tag does not contain

The tag tree predates and does not contain the PR #189 release-preparation
tree. It therefore does not contain the v0.8.0 metadata bump, v0.8.0
changelog/release notes, or the packaged v0.8 work recorded there: source-RAG
upload ergonomics, migration-review tooling, the ApexMarkdown 1.1.12 update,
and associated release hardening.

It also does not contain the subsequent `afterparty` work, including
ApexMarkdown 1.1.13, graph-aware segmented RAG and documentation links,
Context Bundle corrections, IR schemas, source-RAG tool packs and path safety,
export and HTML publication hardening, CLI/documentation-intelligence tools,
nested hierarchy, and the rendered-site search index/UI/publication work in
PRs #231 and #237. This list is a release-impact summary, not an assertion
that every change belongs in a corrective v0.8 release.

## Recovery options (facts and consequences)

| Option | Factual operation | Consequences |
|---|---|---|
| Preserve `v0.8.0`; publish a corrective later release | Leave the public tag/release immutable. Make a new, correctly versioned release from a reviewed commit. | Existing users can still resolve bad `v0.8.0`; correction must be conspicuous in changelog/release notes. Reproducibility of the existing tag is preserved, but it reproducibly builds 0.7.0. |
| Replace `v0.8.0` | Delete/edit the GitHub release, delete the local/remote tag, then create and publish a new annotated tag at a chosen verified commit. | Makes the name resolve to the intended bytes going forward, but breaks anyone who already fetched, pinned, cached, signed against, or cited the old tag/release. Public history is rewritten; coordinate before doing it. |
| Publish a new identifier without reusing `v0.8.0` | Retain the old record and issue a distinct identifier, such as `v0.8.1` or a release-candidate/correction identifier chosen by the owner. | Avoids tag rewrite and makes a new reproducible release point. Package/compiler metadata and changelog must agree with the new identifier; users need clear guidance about the erroneous old release. |

## Owner command cards (do not run blindly)

All cards assume a clean local clone and an explicit, reviewed chosen commit
in `RELEASE_COMMIT`. They are commands for the release owner after choosing a
policy, not commands executed by this investigation.

### A. Preserve the existing tag; publish a corrective release

```bash
git fetch origin --tags
git checkout afterparty
git pull --ff-only origin afterparty
git checkout -b release/v0.8.1-correction
# Update build.zig.zon, src/pipeline.zig, CHANGELOG.md, and release notes to the chosen new identifier.
./scripts/release-gate.sh
git add build.zig.zon src/pipeline.zig CHANGELOG.md docs/changelog.d
git commit -m "chore: prepare v0.8.1 corrective release"
git push -u origin release/v0.8.1-correction
# Merge the reviewed PR to afterparty, then set RELEASE_COMMIT to that merge commit.
git tag -a v0.8.1 "$RELEASE_COMMIT" -m "Boris v0.8.1"
git push origin v0.8.1
gh release create v0.8.1 --repo drawmeanelephant/boris --target "$RELEASE_COMMIT" --title "Boris v0.8.1" --notes-file RELEASE-NOTES.md
```

### B. Replace `v0.8.0` (history-rewriting; coordinate first)

```bash
git fetch origin --tags
# Set RELEASE_COMMIT=e65e6746abbbcf1a8859069bfa0fa3319abd6927 only if that exact tree is the owner-approved release payload.
gh release delete v0.8.0 --repo drawmeanelephant/boris --yes
git tag -d v0.8.0
git push origin :refs/tags/v0.8.0
git tag -a v0.8.0 "$RELEASE_COMMIT" -m "Boris v0.8.0"
git push origin v0.8.0
gh release create v0.8.0 --repo drawmeanelephant/boris --target "$RELEASE_COMMIT" --title "Boris v0.8.0" --notes-file RELEASE-NOTES.md
```

### C. Use a new identifier without rewriting the old release

```bash
git fetch origin --tags
git checkout afterparty
git pull --ff-only origin afterparty
git checkout -b release/v0.8.0-corrected
# Choose and apply the owner-approved new version identifier consistently.
./scripts/release-gate.sh
git add build.zig.zon src/pipeline.zig CHANGELOG.md docs/changelog.d
git commit -m "chore: prepare corrected release"
git push -u origin release/v0.8.0-corrected
# Merge the reviewed PR, then tag its merge commit with the new identifier.
git tag -a "$NEW_TAG" "$RELEASE_COMMIT" -m "Boris $NEW_TAG"
git push origin "$NEW_TAG"
gh release create "$NEW_TAG" --repo drawmeanelephant/boris --target "$RELEASE_COMMIT" --title "Boris $NEW_TAG" --notes-file RELEASE-NOTES.md
```

Before any card: confirm `git show "$RELEASE_COMMIT":build.zig.zon` and
`git show "$RELEASE_COMMIT":src/pipeline.zig` match the release identifier;
run the release gate at the exact candidate; and update the public release
body to disclose the old tag's 0.7.0 metadata if it remains public.

## Verification and limitation

- `zig build` and `zig build test` passed on macOS with Zig 0.16.0.
- `./scripts/release-gate.sh` ran all substantive build, test, deterministic
  RAG/context, fixture, CLI, and temporary-package checks successfully, but
  ended **FAIL** because `docs/STATUS.md` does not contain the required Zig
  `0.16` string. This is a current release blocker under the gate policy.
- The gate's repeated RAG and Context exports were byte-identical. It did not
  establish cross-host reproducibility or sanitizer evidence.
- GitHub API evidence establishes the release record and absence of uploaded
  assets at investigation time. It cannot establish private mirrors, external
  package registries, or prior source-archive downloads.
