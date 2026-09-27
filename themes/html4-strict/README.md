# HTML 4.01 Strict compatibility theme

Select with `--theme themes/html4-strict --target-profile default=html4-strict`.
The layout supplies the complete Strict DOCTYPE, head, and body; it uses only
HTML 4.01 vocabulary. Boris checks the *assembled page*, including every slot,
before publication. See [the profile contract](../../docs/contracts/html4-strict.md).

This compatibility theme deliberately omits the JavaScript search UI and native
HTML5 disclosure behavior. Aside and Details remain visible, but Details are
always expanded. HTML5 landmarks and ARIA labels are not emitted in this mode.
The default theme and ordinary HTML/XHTML outputs are unchanged.
