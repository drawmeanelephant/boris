## 448: opt-in XHTML output profile

`--target-profile NAME=xhtml` selects Oliver's XHTML serializer profile for
one HTML target — an XML-compatible serialization of the same normalized
document, with the default `html` output byte-identical to before. An XHTML
*document* is a layout concern: the layout template emits the XML declaration
+ `<html xmlns="http://www.w3.org/1999/xhtml">` and the page-body slot
receives the XHTML fragment (the fragment serializer is never given fake
wrappers). The profile fails closed on verbatim raw HTML:
`error.RawHtmlNotXmlWellFormed` hard-fails the build with page/offset context
in the diagnostics surface, so flipping a target to XHTML requires a raw-HTML
sweep of its content first. The profile is valid for `build` and `validate`
(the no-publication HTML path renders with it in memory) and is rejected by
non-HTML projections, `check`, and `impact`. Contract updates in
`docs/contracts/cli.md`, `multi-target-isolated-output.md`, and
`oliver-renderer.md`.
