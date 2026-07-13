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

// Compile-time: Zig `usize` must match C `size_t` (apex_render md_len) width.
comptime {
    const md_len_t = @typeInfo(@TypeOf(c.apex_render)).@"fn".params[1].type.?;
    if (@sizeOf(usize) != @sizeOf(md_len_t)) {
        @compileError("usize / size_t size mismatch: cannot pass md.len as size_t safely");
    }
}

pub const ApexError = error{
    RenderFailed,
    OutOfMemory,
};

/// Bounded stress size for large-input tests (keeps CI bounded).
pub const test_large_md_bytes: usize = 64 * 1024;

/// Zig-side view of rendered HTML. Memory is owned by the document
/// Whiteboard arena passed to `render` — never by libc, never by a Zig free.
pub const Html = struct {
    bytes: []const u8,
};

/// C ABI `ApexAllocator.alloc` — allocate from the document Whiteboard.
///
/// `ctx` is a `*std.mem.Allocator` whose storage is stack-local for the
/// enclosing `render` call (see stack-lifetime contract). Apex may call this
/// many times while growing the HTML buffer; each successful allocation returns
/// a non-null pointer. Failure returns null (ordinary C error path → OOM).
fn zigAlloc(ctx: ?*anyopaque, size: usize) callconv(.c) ?*anyopaque {
    const allocator: *std.mem.Allocator = @ptrCast(@alignCast(ctx orelse return null));
    // size == 0: Zig alloc of 0 is legal; return a non-null sentinel via alloc(0)
    // when the child allocator supports it. ArenaAllocator handles 0-size.
    const slice = allocator.alloc(u8, size) catch return null;
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
}

/// Panic guard: arena-backed Apex HTML must never be passed to `apex_free`
/// or `std.heap.c_allocator.free`. Call this only as a documentation /
/// defensive hook if a future code path is tempted to free HTML explicitly.
pub fn forbidApexFree(_: Html) noreturn {
    @panic("apex_free / free must not be called; HTML lifetime is owned by the document arena (reset .free_all)");
}

/// Stable non-null pointer for empty markdown (C requires non-NULL `md` even
/// when `md_len == 0`). Not read when length is zero.
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
    const rc = c.apex_render(
        @ptrCast(prepared.ptr),
        prepared.len,
        &out_ptr,
        &out_len,
        &apex_alloc,
    );

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
}

test "apex render heading in-process" {
    try skipIfHostileEngine();
    const gpa = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const html = try render("# Hello **world**\n\nParagraph.\n", &arena);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h1>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<strong>world</strong>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<p>") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h2>") != null);
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
    try std.testing.expect(std.mem.indexOf(u8, html.bytes, "<h1>") != null);
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
    try std.testing.expect(remainingAbiAssumptions.len >= 5);
    // Ensure each entry is non-empty documentation.
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
