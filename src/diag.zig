//! Structured diagnostics for the content compiler.
//!
//! Strings inside a Diagnostic are owned by the caller's retain allocator
//! (typically the long-lived arena for a compile run).

const std = @import("std");

pub const Severity = enum {
    error_,
    warning,
    info,

    pub fn jsonName(self: Severity) []const u8 {
        return switch (self) {
            .error_ => "error",
            .warning => "warning",
            .info => "info",
        };
    }

    pub fn textName(self: Severity) []const u8 {
        return self.jsonName();
    }
};

/// Closed diagnostic codes for the metadata + graph slice.
pub const Code = enum {
    E_CONTENT_ROOT,
    E_SOURCE_PATH,
    /// Symlinked directory or page file under the content root (v0.1 rejects both).
    E_SYMLINK,
    /// Directory walk revisited a previously seen directory inode (symlink cycle / hard re-entry).
    E_SYMLINK_CYCLE,
    E_ENCODING,
    E_DUP_ID,
    /// Two source paths or entity ids differ only in letter case (ids preserve case).
    E_ENTITY_CASE_COLLISION,
    E_FRONTMATTER,
    E_FRONTMATTER_DUP_KEY,
    E_FRONTMATTER_VALUE,
    E_PARENT_MISSING,
    E_PARENT_SELF,
    E_PARENT_CYCLE,
    /// Parent exists but is itself a satellite (multi-hop chain unsupported in v0.1; hard error).
    E_PARENT_NOT_TRUNK,
    E_INTERNAL,

    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    message: []const u8,
    /// Clear remediation guidance for authors/tools.
    remediation: []const u8 = "",
    /// Content-root-relative path, or empty if not applicable.
    source_path: []const u8 = "",
    line: ?u32 = null,
    column: ?u32 = null,
    /// Related entity id, or empty if unknown.
    id: []const u8 = "",

    pub fn isError(self: Diagnostic) bool {
        return self.severity == .error_;
    }
};

/// Sort diagnostics for deterministic JSON (sourcePath, line, column, code, message).
pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    const path_cmp = std.mem.order(u8, a.source_path, b.source_path);
    if (path_cmp != .eq) return path_cmp == .lt;

    const la = a.line orelse std.math.maxInt(u32);
    const lb = b.line orelse std.math.maxInt(u32);
    if (la != lb) return la < lb;

    const ca = a.column orelse std.math.maxInt(u32);
    const cb = b.column orelse std.math.maxInt(u32);
    if (ca != cb) return ca < cb;

    const code_cmp = std.mem.order(u8, a.code.name(), b.code.name());
    if (code_cmp != .eq) return code_cmp == .lt;

    return std.mem.order(u8, a.message, b.message) == .lt;
}

pub fn sortDiagnostics(diags: []Diagnostic) void {
    std.mem.sort(Diagnostic, diags, {}, lessThan);
}

/// Format one diagnostic line for stderr (no trailing newline).
pub fn formatText(d: Diagnostic, allocator: std.mem.Allocator) ![]u8 {
    const rem = if (d.remediation.len > 0)
        try std.fmt.allocPrint(allocator, " [{s}]", .{d.remediation})
    else
        "";

    if (d.source_path.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}: {s}: {s}{s}", .{
            d.severity.textName(),
            d.code.name(),
            d.message,
            rem,
        });
    }
    if (d.line) |line| {
        const col = d.column orelse 1;
        return std.fmt.allocPrint(allocator, "{s}: {s}: {s}:{d}:{d}: {s}{s}", .{
            d.severity.textName(),
            d.code.name(),
            d.source_path,
            line,
            col,
            d.message,
            rem,
        });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}: {s}: {s}{s}", .{
        d.severity.textName(),
        d.code.name(),
        d.source_path,
        d.message,
        rem,
    });
}

pub fn countErrors(diags: []const Diagnostic) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.isError()) n += 1;
    }
    return n;
}

test "sortDiagnostics orders by path then line" {
    var diags = [_]Diagnostic{
        .{ .severity = .error_, .code = .E_DUP_ID, .message = "b", .source_path = "b.md", .line = 1, .column = 1 },
        .{ .severity = .error_, .code = .E_DUP_ID, .message = "a", .source_path = "a.md", .line = 2, .column = 1 },
        .{ .severity = .error_, .code = .E_DUP_ID, .message = "a1", .source_path = "a.md", .line = 1, .column = 1 },
    };
    sortDiagnostics(&diags);
    try std.testing.expectEqualStrings("a.md", diags[0].source_path);
    try std.testing.expect(diags[0].line.? == 1);
    try std.testing.expectEqualStrings("a.md", diags[1].source_path);
    try std.testing.expect(diags[1].line.? == 2);
    try std.testing.expectEqualStrings("b.md", diags[2].source_path);
}
