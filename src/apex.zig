//! Phase 3: native Apex C-ABI integration.
//!
//! Markdown rendering is an in-process function call — never std.process /
//! ChildProcess. HTML is produced into the caller-provided document
//! `ArenaAllocator` (Whiteboard) so a single `reset(.free_all)` reclaims it.
//!
//! ## ABI contracts (Zig ↔ Apex C) — non-negotiable
//!
//! 1. **Synchronous only.** `apex_render` must complete before this wrapper
//!    returns. Future Apex versions must not defer work that would re-enter
//!    alloc/free after return (no lazy footnote tables, no background threads).
//!
//! 2. **Stack-lifetime `ApexAllocator` (not a global).** The `ApexAllocator`
//!    struct and its `ctx` (`*std.mem.Allocator`) live on the Zig **stack** for
//!    the duration of `render` only. Ownership is explicit and call-scoped.
//!    Apex must not retain `allocator`, `ctx`, input, or output pointers after
//!    `apex_render` returns. (Hosting them on the document arena would also be
//!    valid under the same non-retention rule; we prefer stack so lifetime is
//!    obviously call-bounded and never accidental process-global state.)
//!
//! 3. **No retained C allocation pointers across pages.** Apex must not cache,
//!    intern, or pool any pointer obtained from `ApexAllocator.alloc` beyond
//!    the document that owns the Whiteboard. `zigFree` is an explicit no-op;
//!    the arena is the exclusive lifetime owner. A production Apex that retains
//!    arena *payload* pointers across pages is a use-after-free on the next
//!    document's `free_all` wipe.
//!
//! 4. **Never call `apex_free` on whiteboard HTML.** `apex_free` in the C
//!    header exists only for the libc-malloc path (`allocator == NULL`).
//!    Boris always passes a custom arena allocator; calling `apex_free` on
//!    those bytes is heap corruption. Use `forbidApexFree` / do not free.
//!
//! 5. **Apex must not libc-free allocator memory.** Custom-path buffers are
//!    only released via `ApexAllocator.free` (no-op under Whiteboard) or
//!    bulk arena reset — never `free`/`realloc` from libc on those pointers.
//!
//! 6. **Input is ptr+len only.** No Zig-side `dupe` or NUL-termination of
//!    markdown before the C call.
//!
//! 7. **Status before outputs.** After `apex_render`, Zig checks the C status
//!    **before** reading `out_html` / `out_len`. Non-zero status never
//!    constructs a slice from those parameters (even if a hostile engine left
//!    them dirty). Null output with non-zero length is always rejected.
//!
//! ## Remaining ABI assumptions (not mechanically enforceable)
//!
//! See `remainingAbiAssumptions` and the module tests that document them.
//! Memory safety of the C implementation cannot be proved by Zig alone.

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const c = @cImport({
    @cInclude("apex.h");
});

// Compile-time ABI compatibility — beyond a single width check.
// Declarations must match apex.h via @cImport; we still assert key properties
// so a mismatched header/toolchain fails the build rather than miscompiling.
comptime {
    // 1) Length widths: Zig usize must match C size_t for md_len / out_len.
    const render_info = @typeInfo(@TypeOf(c.apex_render)).@"fn";
    const md_len_t = render_info.params[1].type.?;
    const out_len_ptr_t = render_info.params[3].type.?;
    if (@sizeOf(usize) != @sizeOf(md_len_t)) {
        @compileError("usize / size_t size mismatch: cannot pass md.len as size_t safely");
    }
    // out_len is size_t* in C; after cImport, expect a pointer to size_t-sized int.
    const out_len_child = @typeInfo(out_len_ptr_t).pointer.child;
    if (@sizeOf(usize) != @sizeOf(out_len_child)) {
        @compileError("out_len size_t width mismatch with usize");
    }

    // 2) Parameter arity of apex_render (md, md_len, out_html, out_len, allocator).
    if (render_info.params.len != 5) {
        @compileError("apex_render arity changed; update Zig wrapper and apex-abi contract");
    }

    // 3) Status constants match documented ABI (also runtime-tested).
    if (c.APEX_OK != 0 or c.APEX_ERR_ARGS != 1 or c.APEX_ERR_OOM != 2) {
        @compileError("Apex status constants do not match documented ABI");
    }

    // 4) ApexAllocator layout: three fields (alloc, free, ctx) — field count.
    const alloc_info = @typeInfo(c.ApexAllocator).@"struct";
    if (alloc_info.fields.len != 3) {
        @compileError("ApexAllocator field count changed; update Zig wrapper");
    }

    // 5) Function pointer call conventions are C (cImport should already match).
    // apex_version returns [*c]const u8 / [*:0]const u8.
    _ = @TypeOf(c.apex_version);
    _ = @TypeOf(c.apex_free);
}

pub const ApexError = error{
    RenderFailed,
    OutOfMemory,
};

/// Bounded stress size for large-input tests (keeps CI bounded).
pub const test_large_md_bytes: usize = 64 * 1024;

/// Zig-side view of rendered HTML.
///
/// **Borrowed lifetime:** `bytes` is a view of Whiteboard (arena) memory
/// produced by `render`. It is valid only until the arena is reset or
/// deinitialized (`reset(.free_all)` / `deinit`). Do not free with
/// `apex_free`, libc `free`, or any Zig `free` on these bytes — use
/// `forbidApexFree` as a panic guard if a future path is tempted.
pub const Html = struct {
    bytes: []const u8,

    /// Documents that this buffer is arena-borrowed and must not be freed.
    pub const owns_memory: bool = false;
};

/// C ABI `ApexAllocator.alloc` — allocate from the document Whiteboard.
///
/// `ctx` is a `*std.mem.Allocator` whose storage is stack-local for the
/// enclosing `render` call (see stack-lifetime contract). Apex may call this
/// many times while growing the HTML buffer; each successful allocation returns
/// a non-null pointer. Failure returns null (ordinary C error path → OOM).
fn zigAlloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return null));

    // Zero-byte request: still return a stable non-null pointer when possible.
    // ArenaAllocator accepts alloc(0); do not special-case with a null return
    // (null means OOM to Apex). Checked size: size is already usize from C.
    const n = size; // size_t → usize width verified at comptime

    // Checked arithmetic placeholder for any future size padding/alignment:
    // refuse unrepresentable growth (identity here; documents the rule).
    const alloc_size = std.math.add(usize, n, 0) catch return null;

    const slice = allocator.alloc(u8, alloc_size) catch return null;
    // Zig empty slices should still yield a non-null base for Apex (null = OOM).
    if (@intFromPtr(slice.ptr) == 0) return null;
    return slice.ptr;
}

/// C ABI `ApexAllocator.free` — **explicit no-op**.
///
/// Apex may call free when resizing intermediate buffers (`buf_reserve` in
/// `vendor/apex/apex.c`). Under the Whiteboard model those frees must not
/// return memory to the GPA: HTML and render scratch vanish only when
/// `doc_arena.reset(.free_all)` runs after the page has been fully written.
fn zigFree(_: ?*anyopaque, _: ?*anyopaque, _: usize) callconv(.c) void {
    // Intentionally empty: arena bulk-free is the sole reclamation path.
    // Safe to call any number of times (including after intermediate resizes).
}

/// Panic guard: arena-backed Apex HTML must never be passed to `apex_free`
/// or `std.heap.c_allocator.free`. Call this only as a documentation /
/// defensive hook if a future code path is tempted to free HTML explicitly.
pub fn forbidApexFree(_: Html) noreturn {
    @panic("apex_free / free must not be called; HTML lifetime is owned by the document arena (reset .free_all)");
}

/// Stable non-null pointer for empty markdown (C requires non-NULL `md` even
/// when `md_len == 0`).
///
/// - File-scope `const` → program-lifetime address (not a stack temp).
/// - Apex must bound all reads by `md_len`; with `md_len == 0` the sentinel
///   byte is never read (it is `\0` if a buggy engine peeks one byte).
/// - Safe only because the ABI forbids Apex retaining pointers after return.
const empty_md_sentinel: [1]u8 = .{0};

/// Validate Zig→C pointer/length assumptions before calling `apex_render`.
///
/// - Empty input uses a non-null sentinel pointer (never a null `md`).
/// - Non-empty input must have a non-null base pointer.
/// - Length is `usize` / `size_t` (checked at comptime).
/// Public for ABI contract tests / fuzz harness (pointer+length preconditions).
pub fn prepareMdForC(md: []const u8) ApexError!struct { ptr: [*]const u8, len: usize } {
    if (md.len == 0) {
        return .{ .ptr = &empty_md_sentinel, .len = 0 };
    }
    if (@intFromPtr(md.ptr) == 0) return error.RenderFailed;
    return .{ .ptr = md.ptr, .len = md.len };
}

/// Map C `apex_render` status + output parameters to a Zig `Html` view.
///
/// **Hard rules (tested with hostile/mock outputs):**
/// 1. Check `rc` first; on non-zero, ignore `out_ptr` / `out_len` entirely.
/// 2. On success, reject null pointer with non-zero length.
/// 3. Construct a Zig slice only after status and null/length checks pass.
///
/// This function is the single post-`apex_render` gate used by `render` and by
/// unit tests that simulate a hostile C engine.
pub fn mapRenderResult(rc: c_int, out_ptr: ?[*]u8, out_len: usize) ApexError!Html {
    // --- Status first: never read outputs on error -----------------------
    if (rc != 0) {
        // APEX_ERR_OOM (2) → OutOfMemory; all other non-zero → RenderFailed.
        // Do not inspect out_ptr / out_len (may be intentionally dirty).
        if (rc == c.APEX_ERR_OOM) return error.OutOfMemory;
        return error.RenderFailed;
    }

    // --- Success path: validate then construct slice ---------------------
    if (out_ptr == null) {
        if (out_len != 0) {
            // Null buffer with positive length is an ABI violation.
            return error.RenderFailed;
        }
        return Html{ .bytes = &.{} };
    }

    // Non-null pointer: length may be zero (empty but allocated) or positive.
    // Bounds of the allocation are an Apex responsibility; Zig only forms the
    // declared slice. (Cannot verify extent without allocator metadata.)
    const base: [*]u8 = out_ptr.?;
    return Html{ .bytes = base[0..out_len] };
}

/// Serialize entry into the Apex C engine.
///
/// Product ApexMarkdown (and the thin host adapter) is not proven re-entrant
/// across simultaneous `apex_render` calls: extension registries and other
/// process-global C state race under `--jobs N` / U18. Whiteboards remain
/// per-thread; only the C call is serialized. See
/// `docs/contracts/parallel-rendering.md` (D4).
///
/// Zig 0.16: `std.Thread.Mutex` is gone; `std.Io.Mutex` needs an `Io`. Use the
/// lock-free single-owner `std.atomic.Mutex` with yield while contended so
/// `render` stays Io-free for all call sites.
var render_mutex: std.atomic.Mutex = .unlocked;

fn lockRenderMutex() void {
    while (!render_mutex.tryLock()) {
        std.Thread.yield() catch {
            std.atomic.spinLoopHint();
        };
    }
}

fn unlockRenderMutex() void {
    render_mutex.unlock();
}

/// Render markdown payload via the native Apex C ABI into the Whiteboard arena.
///
/// **Zero-copy contract (input):**
/// Markdown crosses the Zig→C boundary strictly as `md.ptr` + `md.len`.
/// No `dupe`, no NUL-termination, no intermediate Zig buffer. Apex reads the
/// caller's bytes in place (header guarantees: need not be NUL-terminated).
///
/// **Zero-copy contract (output):**
/// On success, `Html.bytes` is a Zig slice *view* of the C `out_html` pointer
/// for `out_len` bytes — i.e. `out_ptr[0..out_len]`. No Zig-side copy of the
/// HTML. Stream with `assemble.writePage` (which flushes), then reclaim via
/// `arena.reset(.free_all)`. Never `apex_free`.
///
/// **Debug watermark:** after `apex_render` returns, Debug builds assert that
/// arena capacity did not shrink. A shrink would mean something outside the
/// arena callbacks freed arena-owned blocks — an ABI violation.
///
/// **Concurrency:** takes `render_mutex` for the duration of `apex_render` so
/// parallel HTML workers never re-enter the C engine concurrently.
pub fn render(md: []const u8, arena: *std.heap.ArenaAllocator) ApexError!Html {
    // Debug: capacity before the C call (must not shrink across the boundary).
    const pre_capacity = if (builtin.mode == .Debug) arena.queryCapacity() else 0;

    // Stack-lifetime ApexAllocator + ctx (not global, not heap-by-default).
    // Valid only for this synchronous call. Apex must not retain either.
    var alloc_iface: std.mem.Allocator = arena.allocator();
    var apex_alloc: c.ApexAllocator = .{
        .alloc = zigAlloc,
        .free = zigFree,
        .ctx = @ptrCast(&alloc_iface),
    };

    // Pre-init outputs; C also zeros them, but we never rely on that alone.
    var out_ptr: [*c]u8 = null;
    var out_len: usize = 0;

    const prepared = try prepareMdForC(md);

    // Absolute zero-copy input: pointer + length only. Apex bounds all reads
    // with md_len (see vendor/apex/apex.c) — never strlen.
    // Hold the engine lock only for the C call (not for post-map / asserts).
    lockRenderMutex();
    const rc = c.apex_render(
        @ptrCast(prepared.ptr),
        prepared.len,
        &out_ptr,
        &out_len,
        &apex_alloc,
    );
    unlockRenderMutex();

    if (builtin.mode == .Debug) {
        const post_capacity = arena.queryCapacity();
        // Capacity may grow (new blocks) but must not shrink mid-call.
        std.debug.assert(post_capacity >= pre_capacity);
    }

    // Status + bounds gate (ignores dirty outputs on error).
    // Convert [*c]u8 to optional [*]u8 without reading through a null.
    const optional_ptr: ?[*]u8 = if (out_ptr == null) null else @ptrCast(out_ptr);
    return mapRenderResult(rc, optional_ptr, out_len);
}

pub fn version() []const u8 {
    const v = c.apex_version();
    return std.mem.span(v);
}

/// Documented ABI assumptions that Zig/tests cannot fully enforce against a
/// hostile or buggy production Apex binary. Listed for auditors.
pub const remainingAbiAssumptions = [_][]const u8{
    "Apex does not retain allocator/ctx/md/out pointers after apex_render returns (synchronous only).",
    "Apex does not call libc free/realloc on custom-allocator memory.",
    "Apex only reads md within [md, md+md_len) and does not use strlen on md.",
    "On success, out_html points at out_len valid bytes of host-allocator memory.",
    "Apex does not write through out_html/out_len after setting them and returning.",
    "Apex does not invoke alloc/free after apex_render returns.",
    "size_t and usize match (enforced comptime for this build; still an ABI target assumption).",
    "Caller's markdown is treated as opaque bytes; compile path validates UTF-8 before Apex.",
};

// =============================================================================
// Tests
// =============================================================================

/// Real markdown-engine expectations are skipped when linked against
/// `apex_hostile.c` (`zig build test-apex-hostile`). Wrapper/mapRenderResult
/// contract tests still run under both engines.
fn skipIfHostileEngine() !void {
    if (build_options.hostile_apex) return error.SkipZigTest;
}

test "apex version linked" {
    const v = version();
    try std.testing.expect(v.len > 0);
    if (!build_options.hostile_apex) {
        try std.testing.expect(std.mem.indexOf(u8, v, "apex-markdown") != null);
        try std.testing.expect(std.mem.indexOf(u8, v, "unified") != null);
    }
}

test "apex render heading in-process" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try render("# Hello **world**\n\nParagraph.\n", &arena);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<strong>world</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<p>") != null);
}

test "apex dual-run HTML is byte-identical on one host" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena_a = std.heap.ArenaAllocator.init(gpa);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(gpa);
    defer arena_b.deinit();
    const md = "# Dual\n\n**bold** and *em*\n";
    const a = try render(md, &arena_a);
    const b = try render(md, &arena_b);
    try std.testing.expectEqualStrings(a.bytes, b.bytes);
}

test "apex render empty md is zero-copy ptr+len path" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    // Empty payload: still md.ptr + md.len (0); no special intermediate buffer.
    const html = try render("", &arena);
    try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
}

test "apex render empty via zero-length slice of real buffer" {
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const buf = "not empty";
    const empty_slice = buf[0..0];
    const html = try render(empty_slice, &arena);
    try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
}

test "apex html slice is a view of whiteboard memory" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const md = "## Title\n\nbody\n";
    const html = try render(md, &arena);

    // Slice is non-empty and points at real bytes Apex wrote (not a Zig dupe
    // of a temporary). After free_all the arena no longer retains capacity.
    try std.testing.expect(html.bytes.len > 0);
    // Real Apex emits header ids: <h2 id="..."> — match open tag prefix.
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h2") != null);
    // Pointer must be non-null — constructed as out_ptr[0..out_len].
    try std.testing.expect(@intFromPtr(html.bytes.ptr) != 0);

    _ = arena.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
}

test "apex render does not shrink arena capacity (debug watermark)" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Warm the arena so capacity is non-zero before a second render.
    _ = try render("# warm\n", &arena);
    const pre = arena.queryCapacity();
    try std.testing.expect(pre > 0);

    _ = try render("# again **bold**\n\npara\n", &arena);
    try std.testing.expect(arena.queryCapacity() >= pre);
}

test "apex large input within bounded test limit" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Build a large but CI-bounded markdown document.
    const line = "word **bold** and *em* and `code`\n";
    const n_lines = test_large_md_bytes / line.len;
    var md_buf: std.ArrayList(u8) = .empty;
    defer md_buf.deinit(gpa);
    try md_buf.ensureTotalCapacity(gpa, n_lines * line.len + 16);
    try md_buf.appendSlice(gpa, "# Big\n\n");
    var i: usize = 0;
    while (i < n_lines) : (i += 1) {
        try md_buf.appendSlice(gpa, line);
    }
    try std.testing.expect(md_buf.items.len >= test_large_md_bytes / 2);

    const html = try render(md_buf.items, &arena);
    try std.testing.expect(html.bytes.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<strong>bold</strong>") != null);
}

test "apex invalid utf8 bytes do not crash (byte-oriented; UTF-8 gated upstream)" {
    try skipIfHostileEngine();
    // Compile path validates UTF-8 before Apex (parser/frontmatter). Direct
    // apex.render is byte-oriented: invalid sequences must not null-deref or
    // infinite-loop. Escaping may pass through or entity-escape individual bytes.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const invalid = "hello \xff\xfe world\n\n# \x80 title\n";
    // Must return success or a defined ApexError — never UB / panic.
    const html = try render(invalid, &arena);
    // Output is some HTML view (may contain replacement-like raw bytes escaped).
    try std.testing.expect(html.bytes.len > 0);
}

test "apex forced allocation failure returns OutOfMemory" {
    try skipIfHostileEngine();
    // Tiny fixed buffer under the arena → zigAlloc eventually returns null →
    // C returns APEX_ERR_OOM → mapRenderResult → error.OutOfMemory.
    var tiny: [128]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    var arena = std.heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();

    // Enough markdown that render needs more than 128 bytes of HTML/scratch.
    const md =
        \\# Title one
        \\
        \\Paragraph with **bold** and *italic* and `code` that expands under HTML.
        \\
        \\# Title two
        \\
        \\More text more text more text more text more text more text.
        \\
    ;
    const result = render(md, &arena);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "apex input is not required to be NUL-terminated" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Payload is a slice into a larger buffer; no trailing NUL after md_len.
    // If Apex used strlen, it would read the 0xFF markers / "POISON" suffix.
    var storage = "Hi **there**\nPOISON\xff\xff\xff".*;
    const md: []const u8 = storage[0..13]; // "Hi **there**\n"
    try std.testing.expect(md[md.len - 1] == '\n');
    // Confirm no NUL at md_len boundary (byte after slice is 'P').
    try std.testing.expect(storage[13] == 'P');

    const html = try render(md, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "POISON") == null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "there") != null);
}

test "apex free callback is no-op under arena (html survives resizes)" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    // Large enough to force buf_reserve growth (C calls free on old buffer).
    // Under Whiteboard, zigFree is a no-op; prior bytes remain until free_all.
    var md_buf: std.ArrayList(u8) = .empty;
    defer md_buf.deinit(gpa);
    try md_buf.appendSlice(gpa, "# Grow\n\n");
    var i: usize = 0;
    while (i < 400) : (i += 1) {
        try md_buf.appendSlice(gpa, "word **bold** and more text to expand HTML buffer ");
    }

    const html = try render(md_buf.items, &arena);
    try std.testing.expect(html.bytes.len > 256);
    // Still readable after intermediate C free callbacks (no-op).
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h1") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<strong>bold</strong>") != null);

    // Reclaim only via arena — never apex_free.
    _ = arena.reset(.free_all);
    try std.testing.expectEqual(@as(usize, 0), arena.queryCapacity());
}

test "Html documents borrowed arena lifetime" {
    try std.testing.expect(!Html.owns_memory);
}

test "zigAlloc zero-size path is safe (via empty success)" {
    // Empty md success may yield null+0 without allocating; separately exercise
    // zero-size through the public render path when C allocates empty.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try render("", &arena);
    try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
}

// --- mapRenderResult / hostile C outputs (wrapper never trusts error outs) ---

test "mapRenderResult: OOM status ignores dirty outputs" {
    // Hostile: non-null garbage pointer + nonzero len on error must not be sliced.
    var fake_buf = [_]u8{ 'X', 'Y', 'Z' };
    const dirty_ptr: ?[*]u8 = &fake_buf;
    const r = mapRenderResult(c.APEX_ERR_OOM, dirty_ptr, 99999);
    try std.testing.expectError(error.OutOfMemory, r);
}

test "mapRenderResult: args error ignores dirty outputs" {
    var fake_buf = [_]u8{ 'A', 'B' };
    const r = mapRenderResult(c.APEX_ERR_ARGS, &fake_buf, 2);
    try std.testing.expectError(error.RenderFailed, r);
}

test "mapRenderResult: unknown nonzero status ignores null and nonzero len" {
    // Hostile: null + huge len on error — must not attempt slice construction.
    const r = mapRenderResult(99, null, 0xdeadbeef);
    try std.testing.expectError(error.RenderFailed, r);
}

test "mapRenderResult: reserved upstream NULL status is render failure, not OOM" {
    const upstream_null_status: c_int = 3;
    const r = mapRenderResult(upstream_null_status, null, 0);
    try std.testing.expectError(error.RenderFailed, r);
}

test "mapRenderResult: success null with nonzero len is rejected" {
    const r = mapRenderResult(c.APEX_OK, null, 42);
    try std.testing.expectError(error.RenderFailed, r);
}

test "mapRenderResult: success null with zero len is empty html" {
    const html = try mapRenderResult(c.APEX_OK, null, 0);
    try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
}

test "mapRenderResult: success non-null forms slice of declared length" {
    var buf = [_]u8{ 'h', 'i' };
    const html = try mapRenderResult(c.APEX_OK, &buf, 2);
    try std.testing.expectEqualStrings("hi", html.bytes);
}

test "mapRenderResult: success non-null zero length is empty view" {
    var buf = [_]u8{ 'x' };
    const html = try mapRenderResult(c.APEX_OK, &buf, 0);
    try std.testing.expectEqual(@as(usize, 0), html.bytes.len);
}

/// Hostile mock of `apex_render`: always fails after deliberately polluting
/// output parameters. Used to prove the Zig wrapper path never constructs a
/// slice from error outputs when going through `mapRenderResult`.
fn hostileApexRender(
    md: ?[*:0]const u8,
    md_len: usize,
    out_html: *?[*]u8,
    out_len: *usize,
    allocator: ?*const c.ApexAllocator,
) c_int {
    _ = md;
    _ = md_len;
    _ = allocator;
    // Intentionally dirty — a correct host must not read these on error.
    var poison = struct {
        var bytes: [4]u8 = .{ 0xde, 0xad, 0xbe, 0xef };
    }.bytes;
    out_html.* = &poison;
    out_len.* = 0xffffffff;
    return c.APEX_ERR_ARGS;
}

test "hostile mock apex: wrapper path never slices dirty error outputs" {
    var out_ptr: ?[*]u8 = @ptrFromInt(0x1); // pre-dirty
    var out_len: usize = 12345;
    const rc = hostileApexRender(null, 0, &out_ptr, &out_len, null);
    // Same gate as real render():
    const result = mapRenderResult(rc, out_ptr, out_len);
    try std.testing.expectError(error.RenderFailed, result);
    // Poison values remain in locals but must not appear as Html.bytes.
}

test "hostile mock apex: OOM with poison never yields Html" {
    var poison_buf = [_]u8{ 'p', 'o', 'i', 's', 'o', 'n' };
    const out_ptr: ?[*]u8 = &poison_buf;
    const out_len: usize = poison_buf.len;
    // Simulate engine that forgot to clear outputs on OOM.
    const result = mapRenderResult(c.APEX_ERR_OOM, out_ptr, out_len);
    try std.testing.expectError(error.OutOfMemory, result);
}

test "prepareMdForC empty uses non-null sentinel" {
    const p = try prepareMdForC("");
    try std.testing.expectEqual(@as(usize, 0), p.len);
    try std.testing.expect(@intFromPtr(p.ptr) != 0);
}

test "prepareMdForC non-empty preserves pointer and length" {
    const md = "abc";
    const p = try prepareMdForC(md);
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqual(@intFromPtr(md.ptr), @intFromPtr(p.ptr));
}

test "remaining ABI assumptions are non-empty audit list" {
    // Exact count: bump deliberately when adding/removing an assumption entry.
    try std.testing.expectEqual(@as(usize, 8), remainingAbiAssumptions.len);
    for (remainingAbiAssumptions) |line| {
        try std.testing.expect(line.len > 10);
    }
}

test "apex_free must not be used on arena html (contract via forbidApexFree doc)" {
    try skipIfHostileEngine();
    // We cannot call forbidApexFree without panicking; document that the
    // success path never references c.apex_free. Compile-time: symbol exists
    // for the libc path only.
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try render("x\n", &arena);
    try std.testing.expect(html.bytes.len > 0);
    // No apex_free call — reclaim via arena only.
    _ = arena.reset(.free_all);
}

test "status constants match documented C ABI" {
    try std.testing.expectEqual(@as(c_int, 0), c.APEX_OK);
    try std.testing.expectEqual(@as(c_int, 1), c.APEX_ERR_ARGS);
    try std.testing.expectEqual(@as(c_int, 2), c.APEX_ERR_OOM);
}

// =============================================================================
// Feature 1 Chat 4 — Unified fidelity (structural asserts, not full Apex suite)
// Plan IDs U1–U17 (Feature 1 campaign; archive/docs/reviews/feature-1-apex-fidelity-spec.md).
// =============================================================================

fn fidelityContains(hay: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, hay, needle) == null) {
        std.debug.print("fidelity: missing {s} in:\n{s}\n", .{ needle, hay });
        return error.TestExpectedEqual;
    }
}

fn fidelityRender(md: []const u8, arena: *std.heap.ArenaAllocator) ![]const u8 {
    const html = try render(md, arena);
    return html.bytes;
}

/// Pin exact HTML for high-value Unified constructs (table / footnote / math /
/// callout). Substring structural checks remain for the rest of U1–U17; these
/// goldens catch Apex version-drift in attribute shape and nesting.
///
/// Pin: ApexMarkdown v1.1.11 Unified via host adapter (Feature 1 Chat 4 +
/// external audit F-004). Update only when intentionally upgrading the pin.
fn fidelityEqualGolden(hay: []const u8, golden: []const u8) !void {
    if (!std.mem.eql(u8, hay, golden)) {
        std.debug.print("fidelity golden mismatch:\n--- got ---\n{s}\n--- want ---\n{s}\n", .{ hay, golden });
        return error.TestExpectedEqual;
    }
}

test "U1 Unified GFM table emits table markup" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
    , &arena);
    try fidelityContains(html, "<table");
    try fidelityContains(html, "<td");
    try fidelityEqualGolden(html,
        \\<table>
        \\<tbody>
        \\<tr>
        \\<td>a</td>
        \\<td>b</td>
        \\</tr>
        \\<tr>
        \\<td>1</td>
        \\<td>2</td>
        \\</tr>
        \\</tbody>
        \\</table>
        \\
    );
}

test "U2 Unified nested lists" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\- item
        \\  - nested
        \\
    , &arena);
    try fidelityContains(html, "<ul>");
    // Nested list inside a list item.
    try fidelityContains(html, "<li>item\n<ul>");
}

test "U3 Unified blockquote" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender("> quote\n", &arena);
    try fidelityContains(html, "<blockquote");
    try fidelityContains(html, "quote");
}

test "U4 Unified fenced code is escaped in pre/code" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\```c
        \\int x = 1 < 2;
        \\```
        \\
    , &arena);
    try fidelityContains(html, "<pre");
    try fidelityContains(html, "<code");
    try fidelityContains(html, "int x = 1");
    // Angle brackets must not open raw tags from code content.
    try std.testing.expect(std.mem.indexOf(u8, html, "< 2") == null or
        std.mem.indexOf(u8, html, "&lt;") != null);
}

test "U5 Unified strikethrough" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender("~~strike~~\n", &arena);
    try fidelityContains(html, "<del>");
    try fidelityContains(html, "strike");
}

test "U6 Unified task list checkbox markup" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\- [ ] task
        \\- [x] done
        \\
    , &arena);
    try fidelityContains(html, "checkbox");
    try fidelityContains(html, "checked");
}

test "U7 Unified footnote ref and backref" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\Hi[^1].
        \\
        \\[^1]: note body
        \\
    , &arena);
    try fidelityContains(html, "footnote");
    try fidelityContains(html, "fnref");
    try fidelityContains(html, "note body");
    try fidelityEqualGolden(html,
        \\<p>Hi<sup class="footnote-ref"><a href="#fn-1" id="fnref-1" data-footnote-ref>1</a></sup>.</p>
        \\<section class="footnotes" data-footnotes>
        \\<ol>
        \\<li id="fn-1">
        \\<p>note body <a href="#fnref-1" class="footnote-backref" data-footnote-backref data-footnote-backref-idx="1" aria-label="Back to reference 1">↩</a></p>
        \\</li>
        \\</ol>
        \\</section>
        \\
    );
}

test "U8 Unified definition list" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\Term
        \\: Definition
        \\
    , &arena);
    try fidelityContains(html, "<dl");
    try fidelityContains(html, "<dt");
    try fidelityContains(html, "<dd");
}

test "U9 Unified math delimiters" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\Inline $x$ and
        \\
        \\$$
        \\y
        \\$$
        \\
    , &arena);
    try fidelityContains(html, "math");
    // Apex emits KaTeX-style delimiters in spans.
    try fidelityContains(html, "\\(x\\)");
    try fidelityEqualGolden(html,
        \\<p>Inline <span class="math inline">\(x\)</span> and</p>
        \\<p><span class="math display">\[
        \\y
        \\\]</span></p>
        \\
    );
}

test "U10 Unified callout NOTE" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\> [!NOTE]
        \\> callout body
        \\
    , &arena);
    try fidelityContains(html, "callout");
    try fidelityContains(html, "callout body");
    try fidelityEqualGolden(html,
        \\<div class="callout callout-note">
        \\<div class="callout-title">note</div>
        \\<div class="callout-content">
        \\<blockquote>
        \\<p>
        \\callout body</p>
        \\</blockquote>
        \\
        \\</div>
        \\</div>
        \\
    );
}

test "U11 Unified IAL heading attributes" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender("## Heading {#custom-id .cls}\n", &arena);
    try fidelityContains(html, "id=\"custom-id\"");
    try fidelityContains(html, "class=\"cls\"");
}

test "U12 Unified fenced div" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\::: {.warning}
        \\fenced div
        \\:::
        \\
    , &arena);
    try fidelityContains(html, "<div");
    try fidelityContains(html, "warning");
    try fidelityContains(html, "fenced div");
}

test "U13 empty and non-NUL-terminated input bounded" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const empty = try fidelityRender("", &arena);
    try std.testing.expectEqual(@as(usize, 0), empty.len);

    var storage = "Hi **there**\nPOISON\xff\xff".*;
    const md: []const u8 = storage[0..13];
    const html = try fidelityRender(md, &arena);
    try std.testing.expect(std.mem.indexOf(u8, html, "POISON") == null);
    try fidelityContains(html, "there");
}

test "U14 custom allocator OOM path safe" {
    try skipIfHostileEngine();
    var tiny: [64]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&tiny);
    var arena = std.heap.ArenaAllocator.init(fba.allocator());
    defer arena.deinit();
    const md =
        \\# Title
        \\
        \\Paragraph with **bold** and enough text that HTML exceeds the tiny arena.
        \\More words more words more words more words more words.
        \\
    ;
    try std.testing.expectError(error.OutOfMemory, render(md, &arena));
}

test "U15 Unified trusted raw HTML passes through while fenced HTML is escaped" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const html = try fidelityRender(
        \\<script type="text/plain" data-boundary="raw">RAW_BOUNDARY</script>
        \\
        \\```html
        \\<script type="text/plain" data-boundary="fenced">FENCED_BOUNDARY</script>
        \\```
        \\
    , &arena);

    // The product host deliberately enables unsafe HTML for trusted authors.
    // This is a renderer-boundary assertion, not a browser-sanitization claim.
    try fidelityContains(html, "<script type=\"text/plain\" data-boundary=\"raw\">RAW_BOUNDARY</script>");
    try fidelityContains(html, "&lt;script");
    try fidelityContains(html, "FENCED_BOUNDARY");
    try std.testing.expect(std.mem.indexOf(u8, html, "<script type=\"text/plain\" data-boundary=\"fenced\">") == null);
}

test "U16 dual-run HTML byte-identical (fidelity alias)" {
    try skipIfHostileEngine();
    var arena_a = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_a.deinit();
    var arena_b = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_b.deinit();
    const md =
        \\| a | b |
        \\|---|---|
        \\| 1 | 2 |
        \\
        \\~~x~~ and `code`
        \\
    ;
    const a = try fidelityRender(md, &arena_a);
    const b = try fidelityRender(md, &arena_b);
    try std.testing.expectEqualStrings(a, b);
}

test "U17 include syntax does not pull disk when includes disabled" {
    try skipIfHostileEngine();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Adapter forces enable_file_includes=false. Include-like syntax must stay
    // literal text — not expand to missing-file errors or sibling disk content.
    const html = try fidelityRender(
        \\Before {{include does-not-exist-anywhere.md}} after
        \\
    , &arena);
    try fidelityContains(html, "{{include does-not-exist-anywhere.md}}");
    try fidelityContains(html, "Before");
    try fidelityContains(html, "after");
}

// =============================================================================
// D4 smoke — concurrent Unified renders vs sequential baselines
// Not a formal proof of all Apex globals; catches cross-talk / non-determinism
// under simultaneous apex_render (product --jobs path stress).
// =============================================================================

test "U18 concurrent Unified renders match sequential baselines (D4 smoke)" {
    try skipIfHostileEngine();
    // Sequential baseline capture may use the testing GPA. Concurrent worker
    // arenas must NOT: std.testing.allocator is not thread-safe and races under
    // U18 (CI Linux/macOS ABRT / segfault on join). page_allocator is safe as
    // a shared parent for per-thread ArenaAllocators.
    const gpa = std.testing.allocator;
    const concurrent_gpa = std.heap.page_allocator;

    // Distinctive tokens per sample catch cross-talk if threads share engine state.
    const samples = [_][]const u8{
        \\| a | b |
        \\|---|---|
        \\| TBL-ALPHA | 2 |
        \\
        ,
        \\Hi[^1] FOOT-BETA.
        \\
        \\[^1]: note body FOOT-BETA
        \\
        ,
        \\Inline $x$ MATH-GAMMA and
        \\
        \\$$
        \\y
        \\$$
        \\
        ,
        \\> [!NOTE]
        \\> callout body CALL-DELTA
        \\
        ,
        \\- item LIST-EPSILON
        \\  - nested LIST-EPSILON
        \\
        ,
        \\```c
        \\int CODE_ZETA = 1 < 2;
        \\```
        \\
        ,
        \\Term DL-ETA
        \\: Definition DL-ETA
        \\
        ,
        \\~~strike STRIKE-THETA~~ and `code STRIKE-THETA`
        \\
    };

    var baselines: [samples.len][]u8 = undefined;
    {
        var i: usize = 0;
        errdefer {
            for (baselines[0..i]) |b| gpa.free(b);
        }
        while (i < samples.len) : (i += 1) {
            var arena = std.heap.ArenaAllocator.init(gpa);
            defer arena.deinit();
            const html = try fidelityRender(samples[i], &arena);
            baselines[i] = try gpa.dupe(u8, html);
        }
    }
    defer for (baselines) |b| gpa.free(b);

    // Unique markers must appear in their own baseline (test setup sanity).
    try fidelityContains(baselines[0], "TBL-ALPHA");
    try fidelityContains(baselines[1], "FOOT-BETA");
    try fidelityContains(baselines[2], "MATH-GAMMA");
    try fidelityContains(baselines[3], "CALL-DELTA");

    const Worker = struct {
        samples: []const []const u8,
        baselines: []const []const u8,
        gpa: std.mem.Allocator,
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            var arena = std.heap.ArenaAllocator.init(self.gpa);
            defer arena.deinit();
            var round: usize = 0;
            while (round < 24) : (round += 1) {
                for (self.samples, 0..) |md, i| {
                    if (self.failed.load(.acquire)) return;
                    _ = arena.reset(.free_all);
                    const html = render(md, &arena) catch {
                        self.failed.store(true, .release);
                        return;
                    };
                    if (!std.mem.eql(u8, html.bytes, self.baselines[i])) {
                        self.failed.store(true, .release);
                        return;
                    }
                    // Cross-talk: no foreign marker in this sample's HTML.
                    const foreign = [_][]const u8{
                        "TBL-ALPHA", "FOOT-BETA", "MATH-GAMMA", "CALL-DELTA",
                        "LIST-EPSILON", "CODE_ZETA", "DL-ETA", "STRIKE-THETA",
                    };
                    for (foreign, 0..) |tok, fi| {
                        if (fi == i) continue;
                        if (std.mem.indexOf(u8, html.bytes, tok) != null) {
                            self.failed.store(true, .release);
                            return;
                        }
                    }
                }
            }
        }
    };

    var worker = Worker{
        .samples = &samples,
        .baselines = &baselines,
        .gpa = concurrent_gpa,
    };

    const thread_count = 8;
    var threads: [thread_count]std.Thread = undefined;
    var spawned: usize = 0;
    errdefer {
        // Only join handles still owned by errdefer (spawn partial failure).
        for (threads[0..spawned]) |t| t.join();
    }
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Worker.run, .{&worker});
        spawned += 1;
    }
    const to_join = spawned;
    spawned = 0; // prevent double-join if later expects fail
    for (threads[0..to_join]) |t| t.join();

    try std.testing.expect(!worker.failed.load(.acquire));
}
