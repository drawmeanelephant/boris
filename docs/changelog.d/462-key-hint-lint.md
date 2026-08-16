Checks: add a static key-hint conformance lint (run as part of the editor
UI checks) that fails CI when a dialog, palette, combobox, or banner
shows a key hint without a matching keydown handler — dialogs must carry
an onkeydown, non-native keys must be handled in the handler body, and
Enter/Esc claims must be backed by a form submit, programmatic focus, or
native dialog/banner behavior.
