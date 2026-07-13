//! Process exit codes and a small CLI result model (milestone 3).
//!
//! Content-level diagnostics (codes like `EDUPLICATEID`) live in `diag.zig`.
//! This module only maps high-level failure classes to process exit status.

const std = @import("std");

/// Process exit codes for the product CLI.
///
/// Contract (see docs/contracts/diagnostics.md):
/// - 0 success
/// - 1 content validation error
/// - 2 usage / CLI error
/// - 3 I/O or system error
pub const ExitCode = enum(u8) {
    success = 0,
    content_error = 1,
    usage = 2,
    io_error = 3,

    pub fn int(self: ExitCode) u8 {
        return @intFromEnum(self);
    }
};

/// High-level failure class used by the CLI and future pipeline stages.
pub const FailureClass = enum {
    none,
    content,
    usage,
    io,

    pub fn exitCode(self: FailureClass) ExitCode {
        return switch (self) {
            .none => .success,
            .content => .content_error,
            .usage => .usage,
            .io => .io_error,
        };
    }
};

/// Controlled result from a CLI dispatch or pipeline stage.
/// `message` is optional human text (not owned; caller retains lifetime).
pub const RunResult = struct {
    class: FailureClass = .none,
    message: ?[]const u8 = null,

    pub fn success() RunResult {
        return .{};
    }

    pub fn usage(message: []const u8) RunResult {
        return .{ .class = .usage, .message = message };
    }

    pub fn content(message: []const u8) RunResult {
        return .{ .class = .content, .message = message };
    }

    pub fn io(message: []const u8) RunResult {
        return .{ .class = .io, .message = message };
    }

    pub fn exitCode(self: RunResult) ExitCode {
        return self.class.exitCode();
    }
};

// --- tests -----------------------------------------------------------------

test "ExitCode values match contract" {
    try std.testing.expectEqual(@as(u8, 0), ExitCode.success.int());
    try std.testing.expectEqual(@as(u8, 1), ExitCode.content_error.int());
    try std.testing.expectEqual(@as(u8, 2), ExitCode.usage.int());
    try std.testing.expectEqual(@as(u8, 3), ExitCode.io_error.int());
}

test "FailureClass maps to ExitCode" {
    try std.testing.expectEqual(ExitCode.success, FailureClass.none.exitCode());
    try std.testing.expectEqual(ExitCode.content_error, FailureClass.content.exitCode());
    try std.testing.expectEqual(ExitCode.usage, FailureClass.usage.exitCode());
    try std.testing.expectEqual(ExitCode.io_error, FailureClass.io.exitCode());
}

test "RunResult helpers" {
    try std.testing.expectEqual(ExitCode.success, RunResult.success().exitCode());
    try std.testing.expectEqual(ExitCode.usage, RunResult.usage("bad flag").exitCode());
    try std.testing.expectEqual(ExitCode.content_error, RunResult.content("dup id").exitCode());
    try std.testing.expectEqual(ExitCode.io_error, RunResult.io("read failed").exitCode());
    try std.testing.expectEqualStrings("bad flag", RunResult.usage("bad flag").message.?);
}
