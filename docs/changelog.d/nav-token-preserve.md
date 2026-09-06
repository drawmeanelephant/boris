## Editor: section nav preserves the launch fragment (#943)

The URL fragment is the editor's launch channel — the session token rides
in it (`api.ts` parses it once at startup). The section nav's click handler
wrote a bare `#<section>` fragment, wiping the token: a reload after any
nav jump came up token-missing.

Nav clicks now rewrite the fragment as `#token=…&section=<id>` (section id
last), so reloading after a jump stays authenticated. The consumed `open=`
launch path is deliberately dropped rather than carried forward —
preserving it would re-open the file on every reload. e2e covers the token
round-trip through reload and the open-param lifecycle.

Refs #942, #941.
