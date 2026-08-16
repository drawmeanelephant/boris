Checks: extend the key-hint conformance lint to the command palette's
state machine — the filter's aria-expanded must track paletteItems, and
every option's Enter handler (plus the palette keydown handler) must
guard execution on the enabled state so Enter on a disabled option stays
inert.
