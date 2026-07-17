# Boris Mascot Generation Retrospective

**Status:** abandoned before packaging  
**Date:** 2026-07-16  
**Subject:** Boris v2 animated pet experiment

## Executive summary

The mascot experiment produced a recognizable Boris otter and a validated set
of standard animation rows plus four validated cardinal look anchors. It did
not reach a shippable Codex v2 pet package because the required 16-direction
look atlas was not completed.

The run consumed approximately **$16–$20 of promotional image-generation
credit**. That cost was not justified by the result. The run is preserved as a
failure-and-process record, not as a product feature or release asset.

The key lesson is operational: a full Codex v2 pet is an atlas-production and
QA workflow, not a single mascot illustration. It requires 9 standard rows, a
four-pose cardinal anchor strip, 2 coherent intermediate direction rows,
deterministic assembly, blind direction QA, continuity checks, chroma cleanup,
and final packaging. The expensive part was discovering that geometry and
direction semantics were not reliable after generation.

## Agents involved

| Agent | ID | Role | Outcome |
|---|---|---|---|
| Galileo | `019f6d98-e2a8-78d1-8cac-786fbae221a3` | Brand discovery for Boris visual cues | Completed; closed |
| Popper | `019f6d9b-43d9-7251-a13b-de3f67f1156d` | Base Boris otter identity image | Completed; selected base copied and source cleaned up |
| Carson | `019f6da6-c6ab-7632-ba88-e2a1700ea1dc` | Repair of the `running` animation row | Completed; successful targeted repair |
| Tesla | `019f6daa-c6c6-7ff1-89c5-ccb90557a5f3` | First cardinal look-direction strip | Rejected; source-edge geometry failed |
| Lagrange | `019f6dad-2495-7ce2-b686-5414e9ccb227` | Second cardinal strip repair | Rejected; repeated tail/edge failure |
| Boole | `019f6db0-b7d0-7f71-81e7-54e941f0c2c8` | Third cardinal strip using simplified/tucked-tail strategy | Passed anchor extraction and was approved |
| Huygens | `019f6db6-8989-7840-8a46-591b464f0ead` | First diagonal look row attempt | Cancelled by user before completion to stop further credit spend |

All visual workers were isolated and instructed to return generated image
paths plus concise QA notes. Completed agents were closed after their work;
the final Huygens job was explicitly shut down when the user cancelled the
run.

## Intended design

Boris was designed as a compact, calm, scrappy river otter:

- charcoal/slate fur
- parchment muzzle and belly
- amber eyes
- rust-red attached neckerchief
- sticker-like silhouette
- no logos, readable text, tobacco, rolling-paper, or SaaS-brand cues

The brand discovery brief translated Boris's project identity into a practical
mascot direction: calm under pressure, graph-aware, practical, and scrappy.

## Process chronology

### 1. Preparation

The run was prepared under `/private/tmp/boris-pet-v2/` using the hatch-pet
workflow. The run manifest specified an 8×11 atlas with 192×208 cells and
`spriteVersionNumber: 2`.

The standard rows were:

1. idle
2. running-right
3. running-left
4. waving
5. jumping
6. failed
7. waiting
8. running
9. review

Rows 9 and 10 of the atlas were reserved for the 16 look directions.

### 2. Base identity

Popper generated the base otter. The selected image was copied to:

`/private/tmp/boris-pet-v2/decoded/base.png`

and preserved as the canonical identity reference at:

`/private/tmp/boris-pet-v2/references/canonical-base.png`

This part worked well. The character was visually consistent and suitable as
the reference for later rows.

### 3. Standard animation rows

The standard rows were generated, extracted, and checked with the deterministic
row tools. Every accepted standard row passed component and extraction checks.

The first `running` row was rejected during visual review because it showed
literal foot-running rather than focused task work. Carson regenerated only
that row with planted feet, paw movement, and a processing pose. The repaired
row passed validation and visual inspection.

`running-left` was safely derived by mirroring the approved `running-right`
row. This was the only deterministic visual derivation allowed by the
workflow.

The intermediate standard atlas and QA artifacts were created at:

- `/private/tmp/boris-pet-v2/final/spritesheet.png`
- `/private/tmp/boris-pet-v2/final/spritesheet.webp`
- `/private/tmp/boris-pet-v2/qa/contact-sheet.png`
- `/private/tmp/boris-pet-v2/qa/previews/`
- `/private/tmp/boris-pet-v2/qa/review.json`

### 4. Cardinal direction failure loop

The look-direction workflow required four grounded cardinal poses in this
order: up, right, down, and left. The important semantic landmarks were eye
direction, muzzle direction, head yaw, and a stable body/tail baseline.

Tesla's first strip was semantically understandable, but tails and whiskers
crossed slot boundaries. Deterministic extraction reported source-edge errors
for directions 000, 090, and 180.

Lagrange attempted a whole-strip repair. The smaller poses improved spacing,
but long sideways tails still crossed the slot boundaries for 000 and 090.

After the same root failure occurred twice, the strategy changed as required:

- tail tucked downward and inward behind the feet
- shorter whiskers
- narrower silhouettes
- wider gutters between poses

Boole generated the third strip with that simplified construction. It passed
`extract_cardinal_anchors.py`, and the composed approved strip was saved at:

`/private/tmp/boris-pet-v2/decoded/look-anchors-approved.png`

This was the strongest successful artifact from the look-direction phase.

### 5. Cancellation

Huygens was assigned the first diagonal look row using the approved cardinal
anchors, canonical base, standard contact sheet, and row-9 layout guide. The
user cancelled the run before the worker completed because the accumulated
credit cost had become unreasonable.

The second diagonal row, final atlas assembly, blind direction workers,
continuity QA, despill, independent final visual QA, and v2 packaging were
never performed.

## What passed

- Boris identity and palette were coherent.
- Base image was suitable as a canonical reference.
- All 9 standard animation rows were produced.
- Standard rows passed deterministic extraction/component checks.
- The `running` semantic repair worked.
- Mirrored `running-left` was appropriate after right-facing visual review.
- Cardinal direction semantics were understandable after simplification.
- The third cardinal strip passed source-edge validation.
- Approved standard and cardinal artifacts remain salvageable.

## What failed or remained incomplete

- The first two cardinal strips failed slot-edge geometry.
- The full 16-direction look system was never completed.
- Row 9 generation was cancelled.
- Row 10 was never generated.
- No final 8×11 atlas was assembled.
- No blind direction QA was run.
- No final continuity or independent visual QA was run.
- No `spriteVersionNumber: 2` pet package was produced.

The mascot therefore must not be described as a completed Codex pet.

## Salvageable artifacts

The run directory is:

`/private/tmp/boris-pet-v2/`

Useful artifacts include:

- `final/spritesheet.webp` — intermediate 8×9 standard-row atlas
- `decoded/look-anchors-approved.png` — validated cardinal anchor strip
- `decoded/` — extracted standard rows
- `qa/` — contact sheets, mechanics notes, and validation reports
- `references/canonical-base.png` — canonical Boris identity reference

The directory is under `/private/tmp` and may be deleted by the operating
system. Copy it to durable storage before attempting a future salvage.

## Why the economics were bad

The expensive work was not the base illustration. It was repeated generation
of geometry-sensitive strips where the model had to satisfy all of these at
once:

- eight exact cells
- transparent/chroma-key-safe boundaries
- no neighboring-slot overlap
- stable scale and baseline
- consistent identity
- correct direction semantics
- attached scarf and tucked tail

The first two cardinal failures shared the same root condition. The workflow
correctly changed strategy after the second failure, but the run still spent
too much credit before the remaining rows could be completed.

## Cheaper policy for a future attempt

Do not restart this full pet workflow casually. If revisited:

1. Keep the approved base, standard rows, and cardinal anchors.
2. Copy the run out of `/private/tmp` first.
3. Use a single-image concept or static mascot asset unless a real Codex pet is
   worth the full atlas cost.
4. Budget the entire 8×11 workflow before generating any new row.
5. Prefer a simpler silhouette with no long tail, scarf, whiskers, or thin
   attached features if the goal is a reliable atlas.
6. Stop after one targeted repair if a row repeatedly fails geometry.
7. Never package an intermediate 8×9 atlas as a v2 pet.

## Final assessment

This was a useful but expensive process experiment. It proved that the Boris
character can be made visually coherent and that the standard animation path
is viable. It did not justify shipping a mascot or spending more project
credit on the remaining atlas.

The correct project decision is to leave the artifacts archived, return focus
to Boris's compiler, migration, documentation, and release work, and revisit a
pet only if there is a concrete product or presentation benefit.
