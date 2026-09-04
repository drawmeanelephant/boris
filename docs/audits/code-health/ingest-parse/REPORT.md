# Code-health audit report — ingest and parse

**Card:** [#810](https://github.com/drawmeanelephant/boris/issues/810) (milestone
[Code health pass](https://github.com/drawmeanelephant/boris/milestone/2), epic
[#807](https://github.com/drawmeanelephant/boris/issues/807))
**Authority:** review only — no product-code changes on this card. Findings
filed individually: [#851], [#852].
**Commit audited:** `main` @ `c7b26186` (branch `audit/810-ingest-parse`)
**Zig:** 0.16.0 (homebrew), macOS arm64 (darwin 27)
**Gate:** `zig build test` green before probes and re-run green after (exit 0).

## Setup

- Fresh branch `audit/810-ingest-parse` from `main` tip `c7b26186` (== `origin/main`).
- `zig build test` → exit 0 before any probe work.
- Black-box probes: `zig build` binary `zig-out/bin/boris` run against a
  scaffolded site (`boris init`) in a tmp tree with replaced `content/`;
  per-probe exit codes and output pasted below.
- Contracts read first: `docs/contracts/scanner.md`,
  `identity-and-paths.md`, `source-provider.md`, `frontmatter.md`.
- Locus files read in full: `src/scanner.zig` (779), `src/identity.zig` (608),
  `src/source_io.zig` (39), `src/source_provider.zig` (282), `src/parser.zig`
  (1352), `src/page.zig` (563).

## Falsification table

| # | Probe | Commands (abridged) | Result | Classification | Evidence |
|---|-------|---------------------|--------|----------------|----------|
| B1 | `parentEntry` / `parent_entry` rejection | `boris init`; write page with each legacy key; `boris --quiet` | Both: `error: EFRONTMATTER: index.md:3:1: unsupported frontmatter key`, exit 1; no silent map to `parent` | Non-issue (contract-conformant) | parser.zig:572-575 else-branch; unit tests `parser.test."parse: legacy parentEntry is unknown key"` / `"...parent_entry..."` OK (unit run 139/140) |
| B0 | Scan edges: nested `includes/`, root `includes/`, `.txt`, `.MD` | tree with `guides/includes/keep.md`, `includes/frag.md`, `notes.txt`, `README.MD`; `boris --quiet` | exit 0; `dist/guides/includes/keep.html` built (nested `includes/` is a normal page tree); no page from root `includes/`, `.txt`, `.MD` | Non-issue | scanner.zig:122-131; unit tests `scan: skips content-root includes/ fragment library`, `scan: ignores .txt and case-variant .MD extensions` OK (110/111) |
| B2 | Odd filename (space) — identity reject | `printf 'x\n' > 'content/my page.md'; boris --quiet` | `error: I/O or system failure: InvalidPath`, exit 3 — **no file named, no EINVALIDPATH code, no remediation** | **Confirmed defect → [#851]** | scanner.zig:261-289 `registerDiscoveredPage` maps all identity errors to bare `InvalidPath`; contrast ContentDirMissing which names the path (repro pasted in #851) |
| B3 | Identity collision (same stem, two extensions) | `content/same.md` + `content/same.mdx`; `boris --quiet` | `error: EDUPLICATEID: same.mdx:1:1: duplicate id "same" (also same.md)`, exit 1 — both paths named | Non-issue | scanner.zig:672-704 (duplicates kept for graph stage); unit test `scan: duplicate entity ids preserved for later diagnostics` OK (118) |
| B4 | Limits: oversize source (1 MiB + 1) | 1,048,596-byte `content/big.md`; `boris --quiet` | `error: EFRONTMATTER: big.md:1:1: source exceeds maximum accepted size`, exit 1 — named diagnostic, not silent truncation | Non-issue | source_io.zig:9-21 (≤ `max_source_bytes + 1` allocation); parser.zig:319-321; unit tests `parse: overlong source is EFRONTMATTER` / `parse: publication source and frontmatter byte boundaries` OK (146/159) |
| B5 | Closing fence at EOF without trailing newline | `printf '---\ntitle: T\n---'` vs `printf '---\ntitle: T\n---\r'` | bare `---` at EOF: build exit 0 (frontmatter closed, empty body); `---\r` at EOF: `EFRONTMATTER unclosed`, exit 1 — asymmetric | **Likely defect → [#852]** | parser.zig:373-391 close-fence scan does not require a newline-terminated line; parser.zig:365-368 opening fence does |
| W1 | Memory adapter vs Dir discovery parity | `zig build test-source-provider` (exit 0) + full unit run | Memory scan skips reserved `includes/`, `.assets` trees, enforces the same extension family, oversized-read bound (`max_source_bytes + 1`), and family mismatch as Dir; both sort via the same `registerDiscoveredPage` + `sortPages` | Non-issue | source_provider.zig:152-192 vs scanner.zig:108-176; unit tests `source_provider.test.*` OK (41-44) |
| W2 | Identity rejection edges (traversal, absolute, case, empty stem, `#?%`, whitespace, oversize) | full unit run | all rejections OK, case preserved, `.mdx` preferred before `.md`, output paths never escape | Non-issue | identity.zig:112-296; unit tests `identity.test.*` OK (28-40) |
| W3 | Frontmatter bounds table vs `page.zig` constants | full unit run | 1 MiB source / 64 KiB block / 32 fields / 512 title / 1024 summary / 64 servings / 255 id+parent / 32×64 tags — all enforced at limit±1 | Non-issue | page.zig:33-66; parser.zig:42-49 re-exports; `parse: publication scalar and collection boundaries` OK |

## Findings

1. **[#851] Confirmed defect (medium):** discovery-time `InvalidPath` surfaces as
   a bare system error with no file, code, or remediation; one stray filename
   bricks the build unlocatably. Locus `src/scanner.zig:261-289`.
2. **[#852] Likely defect (low):** closing fence `---` at EOF without trailing
   newline is accepted while `---\r` at EOF is rejected as unclosed — internally
   inconsistent and in tension with the contract's "complete line" wording.
   Locus `src/parser.zig:373-391`.

Non-issue observations recorded for the record (no action):

- `parent` shape violations are `EFRONTMATTER` while `id` shape violations are
  `EINVALIDPATH` (parser.zig:524-538) — matches the frontmatter contract's
  limits table ("illegal **id** shape → EINVALIDPATH").
- `Memory.init` leaks one canonical path slice only if `index.put` fails OOM
  (source_provider.zig:129) — OOM-path-only, process is aborting; Non-issue.
- `FsIdentity.fromStat` void-inode branch (scanner.zig:61) would make every
  directory share identity `{0}` and turn any two-directory tree into a false
  `SymlinkCycle` — but `std.Io.File.Stat.inode` is `std.posix.ino_t`, an
  integer on every supported target (macOS/Linux/Windows; the `void` variant
  exists only on exotic non-libc targets the compiler is not built for).
  **Insufficient evidence** — latent dead branch, unreachable here.
- `published_at`-requires-`summary` failure reports at the post-loop line
  rather than the `published_at` line (parser.zig:582-584) — cosmetic; the
  message names the field; Non-issue.
- Closing-fence search treats a `---` line with trailing spaces as content
  (not a close) — matches "exactly `---`"; Non-issue.

## Exit checklist

- [x] 4 contracts read before the locus files
- [x] 6 locus files read in full; drift checked both directions
- [x] ≥3 falsification probes (5 black-box runs across B0–B5 + 3 unit gates), ≥2 black-box: satisfied
- [x] Every material observation classified exactly once
- [x] Findings filed individually: #851 (Confirmed), #852 (Likely)
- [x] `zig build test` green before and after probe work (exit 0 both runs)
- [x] Report PR targeting `main` (this PR)
- [x] Close-out comment posted on #810 with the mandated template
