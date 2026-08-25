Checks: extend the key-hint conformance lint to the conflict dialog's
state — an onclose handler must clear conflict/deletedConflict so Keep
editing and Esc cannot leave stale external-change state, and the Load
disk version handler must clear conflict before closing. The dialog now
clears both flags on every close via that onclose handler (previously
Keep editing and Esc left them set).
