---
title: "`src/apex_hostile_test.zig` evidence and cases"
id: docs/boris/src/apex_hostile_test/evidence-and-cases
parent: docs/boris/src/apex_hostile_test
status: draft
tags: [boris, zig, source-reference, evidence, apex_hostile_test]
---

# `src/apex_hostile_test.zig` evidence and cases

## Test harness construction

The test binary is assembled in `build.zig` as follows:

```

apex_hostile_lib_mod  (root: src/apex.zig,  linkApex(..., true),  build_options.hostile_apex=true)
↓ named import "apex"
apex_hostile_root     (root: src/apex_hostile_test.zig,  imports: [.{ "apex", apex_hostile_lib_mod }])
↓
apex_hostile_tests    (b.addTest, root_module = apex_hostile_root)
↓
run_apex_hostile_tests → test_apex_hostile_step ("test-apex-hostile")

```

Key details from `build.zig`:

- `linkApex(apex_hostile_lib_mod, b, true)` compiles `vendor/apex/apex_hostile.c` with `-std=c11 -Wall -Wextra` and sets `link_libc = true`, `addIncludePath("vendor/apex")`. It does **not** add the upstream ApexMarkdown include paths or static archives.
- `hostile_opts` sets `hostile_apex = true` via `apex_hostile_lib_mod.addOptions("build_options", hostile_opts)`. This causes `skipIfHostileEngine()` in `apex.zig`'s embedded tests to return `error.SkipZigTest`.
- `apex_hostile_root` imports `apex_hostile_lib_mod` under the name `"apex"`. This is the `@import("apex")` at the top of `apex_hostile_test.zig`. The test file itself does not call `@cImport`; all C type access is indirect through `apex.zig`'s public exports (`apex.render`, `apex.version`, `apex.Html`, `apex.mapRenderResult`, `apex.prepareMdForC`, `apex.remainingAbiAssumptions`) and through the `c` namespace re-exported implicitly by `mapRenderResult`'s signature requiring `c_int` and `c.APEX_ERR_OOM` etc. — **note:** `apex_hostile_test.zig` actually directly references `c.APEX_OK`, `c.APEX_ERR_ARGS`, `c.APEX_ERR_OOM` via a local `const c = @cImport({ @cInclude("apex.h"); })` — *correction:* the file does not contain `@cImport`. It accesses `c.APEX_OK` etc. through the `apex` module, which re-exports `c` only implicitly. Inspecting the actual source: `apex_hostile_test.zig` uses `c.APEX_ERR_OOM`, `c.APEX_ERR_ARGS`, `c.APEX_OK` and `c.ApexAllocator` directly in `hostileApexRender`. This means either (a) there is a top-level `const c = @cImport(...)` not shown in the file, or (b) these are accessed via `apex.c` re-export. The file as read does not have a local `@cImport` call. In `hostileApexRender`, `c.ApexAllocator` and `c.APEX_ERR_ARGS` appear. Since `apex.zig` does not `pub` the `c` namespace, these symbols are likely accessible because the `apex` module's `c` const is module-level. **This is uncertain** — the exact mechanism by which `c.*` is visible in `apex_hostile_test.zig` without a local `@cImport` warrants verification. The most likely resolution is that `apex.zig` implicitly exports `c` through the named module and Zig's module resolution allows `@import("apex").c` or the C symbols are accessed via a comptime-imported path. If this is wrong, the file would fail to compile.

- `apex_hostile_tests` is **not** included in `test_step` and is **not** in the `apex_needing` array. The hostile binary does not require CMake Apex build. The production binary cannot accidentally link `apex_hostile.c` because `linkApex(root_mod, b, false)` uses `hostile = false` unconditionally.

**Command:**
```

zig build test-apex-hostile

```

***

## Tested declarations and entry points

| Declaration or test | Kind | Purpose | Inputs or setup | Expected result | Contract exercised |
| --- | --- | --- | --- | --- | --- |
| `hostile apex version is the test double` | test | Confirms the hostile C double is linked (not real engine) | `apex.version()` | Returns a string containing `"hostile"` | ABI symbol presence; build isolation |
| `hostile OOM: dirty outputs never become Html` | test | OOM with dirty `out_html`/`out_len` not sliced | `apex.render("@HOSTILE_OOM\n", &arena)` | `error.OutOfMemory` | Status-before-outputs gate; APEX_ERR_OOM mapping |
| `hostile ARGS: dirty outputs never become Html` | test | ARGS error with dirty pointer not sliced | `apex.render("@HOSTILE_ARGS\n", &arena)` | `error.RenderFailed` | Status-before-outputs gate; APEX_ERR_ARGS mapping |
| `hostile unknown status: dirty outputs never become Html` | test | Unknown status code (99) with dirty pointer not sliced | `apex.render("@HOSTILE_UNKNOWN_ERR\n", &arena)` | `error.RenderFailed` | Non-zero non-OOM status → RenderFailed |
| `hostile success null+nonzero length is rejected` | test | ABI violation: success + null + nonzero length | `apex.render("@HOSTILE_NULL_LEN\n", &arena)` | `error.RenderFailed` | Null-ptr + nonzero-len rejection on success path |
| `hostile benign success returns html via arena` | test | End-to-end happy path through hostile double + custom allocator | `apex.render("# hello\n", &arena)` | `Html.bytes` contains `"hostile-ok"` | Custom allocator round-trip; non-null slice construction |
| `hostile empty input is ok` | test | Empty input success path through hostile double | `apex.render("", &arena)` | `Html.bytes.len == 0` | Empty-input zero-length success |
| `mapRenderResult: OOM status ignores dirty outputs` | test | Direct gate test; APEX_ERR_OOM with non-null+large len | `mapRenderResult(APEX_ERR_OOM, &fake_buf, 99999)` | `error.OutOfMemory` | Status-first; dirty pointer not sliced |
| `mapRenderResult: args error ignores dirty outputs` | test | Direct gate test; APEX_ERR_ARGS with non-null+len | `mapRenderResult(APEX_ERR_ARGS, &fake_buf, 2)` | `error.RenderFailed` | Status-first |
| `mapRenderResult: unknown nonzero status ignores null and nonzero len` | test | Gate test; status 99 with null+0xdeadbeef len | `mapRenderResult(99, null, 0xdeadbeef)` | `error.RenderFailed` | Unknown non-zero → RenderFailed; huge len ignored |
| `mapRenderResult: reserved upstream NULL status is render failure, not OOM` | test | Status 3 (reserved) is not misread as OOM | `mapRenderResult(3, null, 0)` | `error.RenderFailed` | Only APEX_ERR_OOM (2) maps to OutOfMemory |
| `mapRenderResult: success null with nonzero len is rejected` | test | ABI violation: APEX_OK + null + 42 | `mapRenderResult(APEX_OK, null, 42)` | `error.RenderFailed` | Null+nonzero-length rejection |
| `mapRenderResult: success null with zero len is empty html` | test | APEX_OK + null + 0 is valid empty result | `mapRenderResult(APEX_OK, null, 0)` | `Html{ .bytes.len == 0 }` | Empty success path |
| `mapRenderResult: success non-null forms slice of declared length` | test | Normal success: non-null ptr + len → slice | `mapRenderResult(APEX_OK, &buf, 2)` where buf = `"hi"` | `Html.bytes == "hi"` | Slice construction from valid ptr+len |
| `mapRenderResult: success non-null zero length is empty view` | test | Non-null ptr + zero len → empty but non-crash | `mapRenderResult(APEX_OK, &buf, 0)` | `Html.bytes.len == 0` | Zero-length view from non-null ptr |
| `hostileApexRender` | helper fn | Zig-side mock that sets dirty 0xdeadbeef outputs before returning APEX_ERR_ARGS | Called by two tests below | Internal; not directly a test entry | Baseline for mock-based gate tests |
| `hostile mock apex: wrapper path never slices dirty error outputs` | test | Exercises `mapRenderResult` with output of `hostileApexRender`; confirms poison values not in `Html` | Full `hostileApexRender` call + `mapRenderResult` | `error.RenderFailed`; poison bytes not reachable | Complete round-trip without C FFI |
| `hostile mock apex: OOM with poison never yields Html` | test | OOM status with a valid-looking pointer + length | `mapRenderResult(APEX_ERR_OOM, &poison_buf, poison_buf.len)` | `error.OutOfMemory` | OOM path ignores all output params |
| `prepareMdForC empty uses non-null sentinel` | test | Empty slice uses static sentinel, not null pointer | `prepareMdForC("")` | `len == 0`, `ptr != 0` | Non-null md pointer for zero-length input |
| `prepareMdForC non-empty preserves pointer and length` | test | Non-empty slice passes through unmodified | `prepareMdForC("abc")` | `len == 3`, `ptr == md.ptr` | Zero-copy input pass-through |
| `remaining ABI assumptions are non-empty audit list` | test | Guards against silent removal of documented assumptions | `remainingAbiAssumptions.len == 8` | Exact count check + `len > 10` per entry | Assumption registry integrity |
| `status constants match documented C ABI` | test | Runtime check of `APEX_OK == 0`, `APEX_ERR_ARGS == 1`, `APEX_ERR_OOM == 2` | Direct constant comparison | All three equal expected values | Status constant contract |
| U1–U18 tests (fidelity + concurrency) | tests (all skipped) | Unified Markdown fidelity and D4 concurrency smoke | `skipIfHostileEngine()` → `error.SkipZigTest` | All skipped; no behavior exercised | N/A in hostile binary |

***

## Hostile-case walkthrough

### `@HOSTILE_OOM` — dirty outputs on OOM error

**Injected behavior:**  
`vendor/apex/apex_hostile.c` detects the control tag `@HOSTILE_OOM` at the start of the markdown input. Before returning `APEX_ERR_OOM` (2), it deliberately sets `*out_html = (char*)(uintptr_t)0xDEADBEEF` and `*out_len = 0xBEEF`. These are unmapped garbage values that would segfault if dereferenced.

**Wrapper boundary exercised:**  
`apex.render` calls `c.apex_render`, receives `rc == 2`, and passes `rc`, `out_ptr`, and `out_len` to `mapRenderResult`. Inside `mapRenderResult`, the first branch checks `if (rc != 0)`, enters it, and checks `if (rc == c.APEX_ERR_OOM)`, which is true. It returns `error.OutOfMemory` without ever evaluating `out_ptr` or `out_len`.

**Expected response:**  
`apex.render` returns `error.OutOfMemory`. The test asserts `std.testing.expectError(error.OutOfMemory, ...)`.

**Forbidden unsafe response:**  
The wrapper must not form the slice `@ptrFromInt(0xDEADBEEF)[0..0xBEEF]`, must not pass `0xDEADBEEF` to any Zig slice or memory function, and must not propagate the dirty pointer as an `Html` value.

**Evidence strength:**  
Directly demonstrated — the C double is executed, the dirty outputs are physically set, and the test observes the correct error without crashing.

**Residual gap:**  
Does not test that `render` would handle an `APEX_ERR_OOM` result from an engine that also wrote a valid allocation into the arena first (partial success before OOM). Does not test the case where the arena itself has committed bytes before the OOM return.

***

### `@HOSTILE_ARGS` — dirty outputs on args error

**Injected behavior:**  
The double sets `*out_html = (char*)(uintptr_t)0xCAFEBABE` and `*out_len = 42` before returning `APEX_ERR_ARGS` (1).

**Wrapper boundary exercised:**  
`mapRenderResult` receives `rc == 1`. The `rc != 0` branch is entered. `rc == c.APEX_ERR_OOM` is false. Falls through to `return error.RenderFailed`. `out_ptr` and `out_len` are never read.

**Expected response:**  
`error.RenderFailed`.

**Forbidden unsafe response:**  
Must not slice from `0xCAFEBABE`. Must not confuse `APEX_ERR_ARGS` with `APEX_ERR_OOM`.

**Evidence strength:**  
Directly demonstrated.

**Residual gap:**  
`APEX_ERR_ARGS` is the only non-OOM non-zero standard status tested through the full `render` call path. The unknown-status case uses `render` too; `APEX_ERR_ARGS` is also tested directly through `mapRenderResult`.

***

### `@HOSTILE_UNKNOWN_ERR` — arbitrary non-zero status

**Injected behavior:**  
The double sets `*out_html = (char*)(uintptr_t)0xFEEDFACE` and `*out_len = 99`, then returns `99` as the status code.

**Wrapper boundary exercised:**  
`mapRenderResult` receives `rc == 99`. The `rc != 0` check is true; `rc == c.APEX_ERR_OOM` (2) is false. Returns `error.RenderFailed`.

**Expected response:**  
`error.RenderFailed`. The `mapRenderResult` direct test for this path also passes `null` and `0xdeadbeef` as the output arguments to confirm they are ignored even in a null+huge-length configuration.

**Forbidden unsafe response:**  
Must not attempt to identify the failure mode from the output values. Must not special-case `99` or treat it as a partial-success signal.

**Evidence strength:**  
Directly demonstrated (full render path) + structurally checked (direct `mapRenderResult` call with null+0xdeadbeef).

**Residual gap:**  
Only tests two specific unrecognized values (99 and 3). Does not test the full integer range or boundary values like `INT_MAX` or `UINT_MAX` cast to `c_int`.

***

### `@HOSTILE_NULL_LEN` — success with null pointer and nonzero length

**Injected behavior:**  
The double returns `APEX_OK` (0) while setting `*out_html = NULL` and `*out_len = 17`. This is documented in `apex-abi.md` as an ABI violation: success must either produce a valid non-null pointer with a matching length, or null with zero length for an empty document. Success + null + nonzero length has no valid interpretation.

**Wrapper boundary exercised:**  
`mapRenderResult` passes the `rc != 0` check (rc is 0). Falls to the success path. `if (out_ptr == null)` is true; `if (out_len != 0)` is true (17 ≠ 0); returns `error.RenderFailed`.

**Expected response:**  
`error.RenderFailed`.

**Forbidden unsafe response:**  
Must not form `null[0..17]`, which is undefined behavior and would access address 0 in Zig. Must not interpret a nonzero length from a null pointer as an empty result.

**Evidence strength:**  
Directly demonstrated.

**Residual gap:**  
Does not test success + null + `SIZE_MAX` length (extreme value). Does not test success + non-null + a length that exceeds the actual allocation (bounds checking is an Apex responsibility acknowledged in `remainingAbiAssumptions`).

***

### Benign success path through custom allocator

**Injected behavior:**  
Any input not matching a control tag (e.g., `"# hello\n"`) causes the double to call `host_alloc(allocator, plen)` where `plen = strlen("<p>hostile-ok</p>") = 17`, copy the string, and return `APEX_OK` with `*out_html = buf` and `*out_len = 17`.

**Wrapper boundary exercised:**  
`zigAlloc` is called with `ctx` pointing at the arena's `std.mem.Allocator` interface; it allocates 17 bytes from the `ArenaAllocator` and returns the pointer. `mapRenderResult` receives `rc == 0`, `out_ptr != null`, and forms `Html{ .bytes = out_ptr[0..17] }`. The test checks `std.mem.indexOf(u8, html.bytes, "hostile-ok") != null`.

**Expected response:**  
Successful `Html` whose `bytes` contains `"hostile-ok"`. The arena owns the allocation; `arena.deinit()` reclaims it.

**Forbidden unsafe response:**  
Must not call `apex_free` on arena-allocated bytes. Must not free via the GPA. Must not copy the bytes to a separate buffer (zero-copy contract).

**Evidence strength:**  
Directly demonstrated — end-to-end: C double allocates via Zig callback, Zig wrapper forms the slice, test reads the content.

**Residual gap:**  
The double does not exercise the `free` callback (`zigFree`) on this path (no intermediate resizes with the 17-byte allocation). The no-op behavior of `zigFree` is tested in the real-engine suite in `apex.zig` (large render forcing `buf_reserve` growth).

***

### Empty input success path

**Injected behavior:**  
`apex_hostile.c`: if `md_len == 0`, sets `*out_html = NULL` and `*out_len = 0`, returns `APEX_OK`. This is the valid empty-document success form.

**Wrapper boundary exercised:**  
`prepareMdForC("")` returns the static `empty_md_sentinel` pointer with `len = 0`. `c.apex_render` is called; the double returns `NULL, 0, APEX_OK`. `mapRenderResult` reaches the `out_ptr == null` + `out_len == 0` branch and returns `Html{ .bytes = &.{} }`.

**Expected response:**  
`html.bytes.len == 0`. Test uses `expectEqual(@as(usize, 0), html.bytes.len)`.

**Forbidden unsafe response:**  
Must not pass a null `md` pointer to C (the sentinel avoids this). Must not form a slice from null+0 that accidentally becomes a dangling reference.

**Evidence strength:**  
Directly demonstrated.

**Residual gap:**  
Does not test that the sentinel byte (`\0`) is never read by the hostile double. The double checks `md_len == 0` first and returns immediately, so this property is exercised behaviorally but only against this particular double, not against an engine that reads `md[^1_0]` even when `md_len == 0`.

***

### `hostileApexRender` + `mapRenderResult` (Zig-only mock)

**Injected behavior:**  
`hostileApexRender` is a Zig function with the same signature as `c.apex_render`. It stores `{0xde, 0xad, 0xbe, 0xef}` in a local struct static buffer, sets `out_html.* = &poison.bytes[^1_0]` and `out_len.* = 0xffffffff`, and returns `c.APEX_ERR_ARGS`. The `hostile mock apex: OOM with poison` variant calls `mapRenderResult(c.APEX_ERR_OOM, &poison_buf, poison_buf.len)` directly without going through any render path.

**Wrapper boundary exercised:**  
Only `mapRenderResult` — these tests bypass `apex.render` entirely, calling the gate function directly with pre-computed rc, ptr, and len values. This isolates the gate logic from the C ABI, proving that the safety property is in the Zig code, not in the C double's behavior.

**Expected response:**  
`error.RenderFailed` for the ARGS case; `error.OutOfMemory` for the OOM case. In both cases, the poison values must not appear in any `Html.bytes`.

**Forbidden unsafe response:**  
The `out_ptr` pointing at the poison buffer must not be dereferenced. The huge `0xffffffff` length must not be used to form a slice.

**Evidence strength:**  
Structurally checked — no C execution involved; the gate logic is directly exercised. This is the strongest form of isolation for the `mapRenderResult` function itself.

**Residual gap:**  
The `hostileApexRender` function does not test the `render` function's *full* path (lock acquisition, `prepareMdForC`, arena watermark, mutex release). It proves only the gate; the hostile C path probes the full path for the same status codes.

***

## Control flow

### Full render path (via hostile C double)

```text
test "hostile OOM: dirty outputs never become Html"
    → apex.render("@HOSTILE_OOM\n", &arena)
        → prepareMdForC("@HOSTILE_OOM\n")          [non-empty: returns original ptr+len]
        → lockRenderMutex()
        → c.apex_render(ptr, len, &out_ptr, &out_len, &apex_alloc)
              ↓  [inside apex_hostile.c]
              starts_with(md, md_len, "@HOSTILE_OOM") == true
              *out_html = 0xDEADBEEF          ← dirty
              *out_len  = 0xBEEF              ← dirty
              return APEX_ERR_OOM (2)
        → unlockRenderMutex()
        → [Debug: arena capacity assert]
        → convert out_ptr (0xDEADBEEF) to optional: non-null
        → mapRenderResult(rc=2, out_ptr=0xDEADBEEF, out_len=0xBEEF)
              rc != 0  → true
              rc == APEX_ERR_OOM  → true
              return error.OutOfMemory          ← dirty ptr NEVER read
    ← std.testing.expectError(error.OutOfMemory, ...)  PASS
```


### Direct gate path (Zig mock, no C)

```text
test "hostile mock apex: wrapper path never slices dirty error outputs"
    → hostileApexRender(null, 0, &out_ptr, &out_len, null)
          poison.bytes = {0xde,0xad,0xbe,0xef}  (local struct static)
          out_ptr.* = &poison.bytes[^1_0]
          out_len.* = 0xffffffff
          return APEX_ERR_ARGS (1)
    → mapRenderResult(rc=1, out_ptr=&poison, out_len=0xffffffff)
          rc != 0  → true
          rc == APEX_ERR_OOM  → false
          return error.RenderFailed              ← poison bytes unreachable
    ← std.testing.expectError(error.RenderFailed, ...)  PASS
```


### Success path (benign double)

```text
test "hostile benign success returns html via arena"
    → apex.render("# hello\n", &arena)
        → prepareMdForC("# hello\n")            [returns original ptr+len]
        → lockRenderMutex()
        → c.apex_render(ptr, 8, &out_ptr, &out_len, &apex_alloc)
              ↓  [inside apex_hostile.c]
              no control tag matched
              host_alloc(&apex_alloc, 17)
                  → apex_alloc.alloc(ctx, 17)
                      → zigAlloc(ctx=&alloc_iface, 17)
                          → arena.allocator().alloc(u8, 17)  [succeeds]
                          → return slice.ptr
              ```
              memcpy(buf, "<p>hostile-ok</p>", 17)
              ```
              *out_html = buf   (arena-owned ptr)
              *out_len  = 17
              return APEX_OK (0)
        → unlockRenderMutex()
        → mapRenderResult(rc=0, out_ptr=buf, out_len=17)
              rc != 0  → false
              out_ptr != null  → true
              return Html{ .bytes = buf[0..17] }  ← arena view, no copy
    ← html.bytes contains "hostile-ok"  PASS
```


***
