//! Freestanding Wasm entry for the Oliver render seam (#301 M0).
//!
//! This is a compile-target wrapper around `src/render.zig`. It is not the
//! product `compileBundle` ABI (that is M5). Hosts allocate input through
//! `boris_alloc`, call `boris_render`, then read the last result from
//! exported linear memory.

const std = @import("std");
const render = @import("render.zig");

const allocator = std.heap.wasm_allocator;

var last_out: []u8 = &.{};

pub fn panic(msg: []const u8, _: ?*std.builtin.StackTrace, _: ?usize) noreturn {
    _ = msg;
    @trap();
}

export fn boris_alloc(len: u32) u32 {
    if (len == 0) return 0;
    const s = allocator.alloc(u8, len) catch return 0;
    return @intCast(@intFromPtr(s.ptr));
}

export fn boris_free(ptr: u32, len: u32) void {
    if (ptr == 0 or len == 0) return;
    const p: [*]u8 = @ptrFromInt(ptr);
    allocator.free(p[0..len]);
}

/// Render Markdown at `in_ptr`/`in_len`. Returns 0 on success; negative
/// codes match `renderErr`. The HTML lives in the last-result buffer until
/// the next render or `boris_result_free`.
export fn boris_render(in_ptr: u32, in_len: u32) i32 {
    freeLast();
    if (in_ptr == 0 and in_len != 0) return -6;
    const input: []const u8 = if (in_len == 0)
        &.{}
    else
        @as([*]const u8, @ptrFromInt(in_ptr))[0..in_len];

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const html = render.render(input, &arena) catch |err| return renderErr(err);
    last_out = allocator.dupe(u8, html.bytes) catch return -1;
    return 0;
}

export fn boris_result_ptr() u32 {
    return if (last_out.len == 0) 0 else @intCast(@intFromPtr(last_out.ptr));
}

export fn boris_result_len() u32 {
    return @intCast(last_out.len);
}

export fn boris_result_free() void {
    freeLast();
}

fn freeLast() void {
    if (last_out.len == 0) return;
    allocator.free(last_out);
    last_out = &.{};
}

fn renderErr(err: render.RenderError) i32 {
    return switch (err) {
        error.OutOfMemory => -1,
        error.InputTooLarge => -2,
        error.WriteFailed => -3,
        error.NoSpaceLeft => -4,
        error.RawHtmlNotXmlWellFormed => -5,
    };
}
