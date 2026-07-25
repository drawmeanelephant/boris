---
title: "`src/apex_hostile_test.zig` overview"
id: docs/boris/src/apex_hostile_test
status: draft
tags: [boris, zig, source-reference, apex_hostile_test]
---

# `src/apex_hostile_test.zig`

> Analytical source-reference documentation. Normative behavior remains in the
> implementation and applicable contracts.

## Satellites

* [[docs/boris/src/apex_hostile_test/surface-and-execution|Surface and execution]]
* [[docs/boris/src/apex_hostile_test/evidence-and-cases|Evidence and cases]]
* [[docs/boris/src/apex_hostile_test/review-state|Review state]]

## Executive summary

`src/apex_hostile_test.zig` is a dedicated ABI hostility test suite for the Zig wrapper over the ApexMarkdown C engine. Its sole purpose is to verify that `src/apex.zig` — specifically the `mapRenderResult` gate and the `render` function — behaves correctly when the underlying C implementation violates or strains the documented ABI. It does this not by testing the real ApexMarkdown engine but by exercising the wrapper against `vendor/apex/apex_hostile.c`, a hand-written C test double that deliberately injects undefined, malformed, or adversarial output in response to known control strings in the markdown input.

The file exists because Zig cannot prove any property about C memory behavior across the `extern` boundary. The wrapper in `apex.zig` makes explicit commitments: it checks the return status *before* reading output parameters, it rejects null pointer + nonzero length as an ABI violation, and it never constructs a Zig slice from dirty error outputs. These commitments are not purely structural — they must survive a C implementation that actively tries to subvert them. `apex_hostile_test.zig` instantiates that adversarial C to prove the commitments hold in executable form.

The system boundary protected is the Zig/C ABI seam: specifically the four parameters and return value of `apex_render`, the `ApexAllocator` struct callbacks, and the `apex_version` symbol. The file is not testing content correctness; it is testing that an antagonistic or buggy C engine cannot cause the Zig wrapper to construct unsafe slices, read dirty pointers, misinterpret error codes, or corrupt the arena.

The file is executed by the dedicated build step `zig build test-apex-hostile`. This step constructs a separate test binary whose root module is `src/apex_hostile_test.zig`; that module imports `src/apex.zig` under the named module `"apex"`, and the `apex` module variant is linked against `vendor/apex/apex_hostile.c` rather than the real `vendor/apex/apex.c` + upstream static archives. No real ApexMarkdown engine is involved. The `build_options.hostile_apex` flag is set to `true` for this binary, causing tests inside `apex.zig` that call `skipIfHostileEngine()` to be skipped, while all tests in `apex_hostile_test.zig` run unconditionally.

Beyond the six tests that interact with the hostile C double via the full `render` call path, the file also contains a large suite of direct `mapRenderResult` unit tests, a small set of `prepareMdForC` tests, a hand-written `hostileApexRender` Zig function that stands in for a C call and pollutes outputs before returning an error, and the complete U1–U18 fidelity block inherited from `apex.zig` — which is silently skipped in this binary because `skipIfHostileEngine()` returns `error.SkipZigTest` for every U-test.

The confidence the file provides is specific and bounded: it demonstrates, in executable form, that the wrapper does not slice from dirty error outputs for the four hostile error scenarios the C double implements, that success+null+nonzero-length is rejected, and that benign success through the custom allocator works end-to-end. It does not prove properties of the real Apex engine, does not exercise concurrent hostility, does not test allocator callback attacks where a hostile engine calls `alloc`/`free` after `apex_render` returns, and does not test pointer retention across document resets.

***

## Classification

| Property | Assessment |
| --- | --- |
| Primary classification | ABI hostile-double integration test |
| Conceptual domain | Zig/C boundary safety; wrapper correctness; error-status handling |
| Build or test root | Root module of the `test-apex-hostile` test binary |
| Production runtime dependency | None — compiled only for `zig build test-apex-hostile` |
| Expected execution command | `zig build test-apex-hostile` |
| Main collaborators | `src/apex.zig` (wrapper under test), `vendor/apex/apex_hostile.c` (hostile C double), `vendor/apex/apex.h` (ABI header), `build.zig` (`apex_hostile_lib_mod` + `apex_hostile_root` module declarations) |
| Documentation depth warranted | High — this is the primary executable proof of the wrapper's safety commitments |

***

## Role in the Boris architecture

`src/apex_hostile_test.zig` has no relationship to the product binary. It is not imported by any non-test source file and is not referenced from `src/main.zig` or any pipeline module. It is the root source file of an entirely separate test executable assembled only when `zig build test-apex-hostile` is invoked.

Within the Apex subsystem, the division is:

- `src/apex.zig` is both the production Zig wrapper and, in its own embedded `test` blocks, the normal test suite exercised against the *real* engine under `zig build test` (via the `apex_tests` step that uses `linkApex(apex_mod, b, false)`).
- `src/apex_hostile_test.zig` is the *separate* test root that imports `src/apex.zig` as a named module (`"apex"`) wired to `apex_hostile.c`. It does not re-link the real engine; it does not depend on `ensure_apex.step`. The `build.zig` proof: the `apex_hostile_tests` step is absent from the `apex_needing` array, confirming it intentionally does not trigger the CMake ApexMarkdown build.

Against the real ApexMarkdown engine: the normal `zig build test` suite (embedded in `apex.zig`) exercises actual rendering fidelity, large inputs, NUL-termination boundaries, allocation failure, and the U1–U18 Unified fidelity suite. Those tests are skipped in the hostile binary because `skipIfHostileEngine()` checks `build_options.hostile_apex`, which is set to `true` only for `apex_hostile_lib_mod`.

Against the hostile C double: `apex_hostile_test.zig` exercises only the cases the double implements: four named error injections (`@HOSTILE_OOM`, `@HOSTILE_ARGS`, `@HOSTILE_UNKNOWN_ERR`, `@HOSTILE_NULL_LEN`), one benign success path, and one empty-input success path. The wrapper boundary (`mapRenderResult`) is also tested directly using both canned C status codes and a hand-written `hostileApexRender` Zig function, bypassing the C call entirely to prove the gate logic independently of any C execution.

The file is specialized ABI validation, separate from the normal test suite by design. It cannot accidentally be included in the default `zig build test` step — `apex_hostile_root` and its step (`test_apex_hostile_step`) are not added to `test_step`'s dependencies.

***
