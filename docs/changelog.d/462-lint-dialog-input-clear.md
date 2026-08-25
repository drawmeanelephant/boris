check(editor): lint that create/rename dialogs reset their path on close

The key-hint lint now requires the create and rename dialogs to reset
their path input on every close path. Identified semantically (by their
Create file / Rename file submit buttons, no name-matching), each dialog
must carry an `onclose` handler assigning its `bind:value` path variable,
so Esc (native dialog cancel) can never leave a half-typed path behind.

This exposed a live gap: neither dialog had an `onclose`, so Esc and
Cancel left whatever was typed in `createPath`/`renamePath` for the next
open. Both now reset on close — create back to the `content/new-page.md`
default, rename to an empty string (it is re-seeded from `activePath` on
open). Self-test fixtures grew to 31.
