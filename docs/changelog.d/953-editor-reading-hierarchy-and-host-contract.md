### Changed

- The editor now carries reading order in type: one documented scale in
  `lib/tokens.css` (meta → body → sub-pane title → pane title → app title),
  a 1.55 prose line-height with a readable measure, and a shared pane header
  row so a title, its lede, and its actions stop competing at the same size.
  Pane titles rise above body copy, `h4` group labels become small-caps
  labels, field labels step below prose, the Problems result chip no longer
  squeezes its lede into a word-per-line column, and Focus writing mode scales
  its document headings with the chosen text size. Presentation only — no
  endpoint, contract, or pipeline change. Links:
  [editor README](/editor/README.md#reading-hierarchy-and-pane-headers),
  [issue #418](https://github.com/drawmeanelephant/boris/issues/418).
- The Project pane renders the project as an indented, collapsible directory
  tree derived from the host's flat path list, so a long project path stops
  breaking mid-token. A row shows its own path segment and indentation carries
  the rest; folder rows are named disclosure buttons with `aria-expanded` and a
  CSS-only caret, and the 200-file budget still counts files only. Each file row
  keeps its full project-relative path as its accessible name and tooltip, the
  filter still matches whole paths, collapsed folders persist and are validated
  on load, and opening a file expands the folders above it. The host's file list
  stays flat — the tree is derived presentation and holds no directory model of
  its own. Links: [editor README](/editor/README.md#project-file-tree),
  [issue #418](https://github.com/drawmeanelephant/boris/issues/418).
- The editor host API is now a normative contract, so the surface cannot drift:
  [editor-host.md](/docs/contracts/editor-host.md) pins the loopback
  transport/security discipline and launch line, the closed endpoint surface
  with its payloads and error taxonomy, author-owned file operations and
  fingerprint/atomic-save rules, the fixed Boris command allowlist and artifact
  version negotiation, both managed daemons (validation, watch) with their
  start/stop/backoff/reaping contract and dist-writer exclusion, and the
  preview origin. It also records the compiler-serve reconciliation as open
  work and names each black-box script that pins a section. Docs plus one type
  correction: the shell declared `hello_schema` as a string while the host has
  always sent a number.
- The editor host contract is now executable: new
  `editor/scripts/test-host-contract.sh` parses the endpoint table and error
  taxonomy out of [editor-host.md](/docs/contracts/editor-host.md), reconciles
  both against the host's own route table and error set in both directions,
  probes every documented endpoint for its exact method set, rejects generated
  near-miss and plausible-but-absent `/api/*` paths, and drives **every** code in
  the taxonomy to its documented status with a live request — a 50 000-file
  fixture, a directory where a page is expected, and four stub-compiler/host
  scenarios — so a documented code that no request can raise now fails the
  build instead of rotting as a "reserved" row. It also floods the watch event
  ring with two stub compilers to pin the §7.3 bounds: the 100-event cap
  (`gap`, `oldest_seq`, `dropped_lines`, and the rule that an unparseable line
  consumes no `seq`) and the ~4 MiB byte budget, where eviction is byte-driven
  rather than count-driven. The same sweep removed `corrupt_recovery`, which no
  handler could raise. It runs as a stage of
  `editor/scripts/test-editor-gate.sh`, so a route or code that drifts from the
  contract fails CI. The first run found a real defect the contract had
  documented but the host did not honor: `POST /api/commands/run` let runner
  errors escape, so an invalid command request or an unrecognized artifact
  version closed the connection with no response at all instead of the
  documented `400 invalid_command_request` / `502 unsupported_boris_artifact`.
  The handler now maps them like every other endpoint.
- Corrected two stale claims in the editor README: the watch-admin section
  still called the editor's watch UI a non-goal, and M5 still justified the
  host's preview origin with a compiler serve mode not existing — that shipped
  as `boris watch --serve` ([CLI contract](/docs/contracts/cli.md)). M5 now
  records the overlap and the reconciliation as open work instead of a settled
  rationale. Docs only.
