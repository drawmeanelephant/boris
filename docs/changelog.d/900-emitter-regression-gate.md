### Security

- `zig build test` now fails when a machine-facing emitter bypasses the output
  encoder. [`src/artifact_invariants.zig`](/src/artifact_invariants.zig) audits
  published bytes for structural breakouts,
  [`src/emitter_hostile_test.zig`](/src/emitter_hostile_test.zig) compiles the
  hostile trees under [`fixtures/hostile-output/`](/fixtures/hostile-output) through
  the real emitters, and
  [`src/emitter_discipline_test.zig`](/src/emitter_discipline_test.zig) requires
  every `src/*.zig` to be classified as an emitter with its encoder or explicitly
  as a non-emitter — so a new module of any name fails the build until someone
  records what it is. `fixtures/hostile-output/legitimate-punctuation/` asserts the
  encoders leave ordinary content untouched.
