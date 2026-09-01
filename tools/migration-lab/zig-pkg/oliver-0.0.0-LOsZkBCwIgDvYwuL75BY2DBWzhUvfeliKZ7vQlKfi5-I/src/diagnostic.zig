//! Structured diagnostics.
//!
//! Oliver does not return `null` or silently malformed output when it
//! encounters trouble. Diagnostics carry a severity, a stable machine-readable
//! code, a byte offset, a line/column, a source span, and a short human
//! message. The vertical slice produces no diagnostics for well-formed input:
//! its parsers either succeed or degrade to text where the dialect permits
//! (that degradation *is* the documented behavior, not an error). Structured
//! diagnostic codes arrive with the malformed-input policies of later
//! milestones.
//!
//! Resource and API failures (out of memory, input too large) are returned as
//! Zig errors by `oliver.parse`, never as diagnostics, so true failures stay
//! distinguishable from markup interpretation.

const std = @import("std");
const source = @import("source.zig");

pub const Severity = enum {
    note,
    warning,
    err,
};

/// A single diagnostic.
///
/// `code` is a short stable identifier such as `"unclosed-code-fence"`; it is
/// a string rather than an enum so the set can grow without a breaking enum
/// change. `offset`, `line`, and `column` are 1-based positions; `span` is the
/// half-open byte range (may be empty).
pub const Diagnostic = struct {
    severity: Severity,
    code: []const u8,
    offset: u32,
    line: u32,
    column: u32,
    span: source.Span,
    message: []const u8,
};

test "diagnostic: construction and basic fields" {
    const d = Diagnostic{
        .severity = .warning,
        .code = "example",
        .offset = 4,
        .line = 1,
        .column = 5,
        .span = .{ .start = 4, .end = 9 },
        .message = "an example diagnostic",
    };
    try std.testing.expectEqual(Severity.warning, d.severity);
    try std.testing.expectEqualStrings("example", d.code);
    try std.testing.expectEqual(@as(u32, 4), d.offset);
    try std.testing.expectEqual(@as(u32, 5), d.column);
    try std.testing.expectEqual(@as(u32, 5), d.span.len());
}
