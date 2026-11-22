### Fixed

- Fixed a use-after-free abort in the editor validation daemon when
  `/api/validate-state` or a validate demand polled during a torn report rewrite
  (parse into a staged arena before swapping `result_arena`, keep post-save
  cycles pending until a complete report parses, replace
  `validate --watch --report` atomically via temp-and-rename, and preserve
  editor host logs on integration script failure). Links:
  [editor host contract](/docs/contracts/editor-host.md),
  [#1170](https://github.com/drawmeanelephant/boris/issues/1170).
