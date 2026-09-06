## Editor: the Graph nav link is honestly disabled while no file is open (#944)

The Graph pane exists only once a file is open — with none, the Source pane
shows its graph-empty status band instead, so the Graph nav link could
never jump, never become current, and never explain itself.

The link now carries `aria-disabled="true"` with a tooltip and muted
styling while its target is absent, and activating it reports the reason
("Graph is available once a file is open.") through the editing-status
live region instead of doing nothing. The link stays focusable so the
condition remains discoverable, re-enables automatically when a file
opens, and the scrollspy still never marks an absent section current.

SectionNav gains an `unavailable` map (id → reason) and an optional
`onBlockedNav` callback; App derives availability from the buffer state.
e2e covers both pane states.

Refs #942, #941.
