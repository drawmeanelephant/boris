Checks: extend the key-hint conformance lint to the resolution dialog's
pending state — an onclose handler must assign pendingResolution to null
and each resolve function must null it before proceeding, so Esc cannot
leave a stale Save & action behind after the dialog closes. The dialog
itself now clears pendingResolution on every close via that onclose
handler (Esc previously left it set).
