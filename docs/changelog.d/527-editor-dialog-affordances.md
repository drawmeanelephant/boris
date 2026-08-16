### Fixed

- The editor command palette can be dismissed with Cancel or a backdrop
  click, secondary dialog actions now carry the same key-hint pattern as
  cancel/primary, and dismissing a dialog returns focus to the control that
  opened it. Closed dialogs stay out of the accessibility tree so generic
  names such as Cancel do not collide
  ([#464](https://github.com/drawmeanelephant/boris/issues/464),
  [#525](https://github.com/drawmeanelephant/boris/issues/525),
  [#526](https://github.com/drawmeanelephant/boris/issues/526),
  [#527](https://github.com/drawmeanelephant/boris/issues/527)). See the
  [editor guide](/content/guides/editor.md).
