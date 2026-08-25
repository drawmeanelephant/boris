//! Bounded, metadata-only diagnostic packets for author-initiated copying.
//! Source excerpts and absolute project identities are never included.

const std = @import("std");

pub const max_packet_bytes = 4096;

pub const Input = struct {
    compiler_id: []const u8,
    editor_id: []const u8,
    command_mode: []const u8,
    failure_class: []const u8,
    severity: []const u8,
    code: ?[]const u8,
    message: []const u8,
    remediation: []const u8,
    source_path: ?[]const u8,
    line: ?u32,
    column: ?u32,
    origin: []const u8,
    position_confidence: []const u8,
    private_project_root: []const u8,
};

pub fn build(allocator: std.mem.Allocator, input: Input) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "Boris diagnostic packet\n");
    try appendField(&output, allocator, "boris", input.compiler_id, input.private_project_root, 128);
    try appendField(&output, allocator, "editor", input.editor_id, input.private_project_root, 128);
    try appendField(&output, allocator, "command", input.command_mode, input.private_project_root, 64);
    try appendField(&output, allocator, "exit_class", input.failure_class, input.private_project_root, 64);
    try appendField(&output, allocator, "severity", input.severity, input.private_project_root, 32);
    try appendField(&output, allocator, "code", input.code orelse "unstructured", input.private_project_root, 128);
    try appendField(&output, allocator, "message", input.message, input.private_project_root, 1024);
    if (input.remediation.len > 0) {
        try appendField(&output, allocator, "remediation", input.remediation, input.private_project_root, 1024);
    }
    if (input.source_path) |path| {
        try appendField(&output, allocator, "source", if (safeRelativePath(path)) path else "<redacted>", input.private_project_root, 512);
    } else {
        try output.appendSlice(allocator, "source: none\n");
    }
    if (input.line) |line| {
        var position_buffer: [64]u8 = undefined;
        const position = if (input.column) |column|
            try std.fmt.bufPrint(&position_buffer, "{d}:{d}", .{ line, column })
        else
            try std.fmt.bufPrint(&position_buffer, "{d}", .{line});
        try appendField(&output, allocator, "position", position, input.private_project_root, 64);
    } else {
        try output.appendSlice(allocator, "position: none\n");
    }
    try appendField(&output, allocator, "origin", input.origin, input.private_project_root, 64);
    try appendField(&output, allocator, "position_confidence", input.position_confidence, input.private_project_root, 64);
    try output.appendSlice(allocator, "context: metadata only; source excerpt omitted\n");
    if (output.items.len > max_packet_bytes) return error.PacketTooLarge;
    return output.toOwnedSlice(allocator);
}

fn appendField(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    label: []const u8,
    value: []const u8,
    private_root: []const u8,
    max_value_bytes: usize,
) !void {
    const sanitized = try sanitize(allocator, value, private_root, max_value_bytes);
    defer allocator.free(sanitized);
    try output.appendSlice(allocator, label);
    try output.appendSlice(allocator, ": ");
    try output.appendSlice(allocator, sanitized);
    try output.append(allocator, '\n');
}

fn sanitize(allocator: std.mem.Allocator, input: []const u8, private_root: []const u8, limit: usize) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var index: usize = 0;
    while (index < input.len and output.items.len < limit) {
        if (private_root.len > 0 and std.mem.startsWith(u8, input[index..], private_root)) {
            const replacement = "<project>";
            if (output.items.len + replacement.len > limit) break;
            try output.appendSlice(allocator, replacement);
            index += private_root.len;
            continue;
        }
        const byte = input[index];
        if (byte < 0x20 or byte == 0x7f) {
            try output.append(allocator, ' ');
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch 1;
        const available = @min(sequence_len, input.len - index);
        if (output.items.len + available > limit) break;
        if (sequence_len == 1 or std.unicode.utf8ValidateSlice(input[index .. index + available])) {
            try output.appendSlice(allocator, input[index .. index + available]);
        } else {
            try output.append(allocator, '?');
        }
        index += available;
    }
    if (index < input.len and output.items.len + 3 <= limit) try output.appendSlice(allocator, "...");
    return output.toOwnedSlice(allocator);
}

fn safeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfAny(u8, path, "\\\x00") != null) return false;
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0 or std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return false;
    }
    return true;
}

test "packet is bounded, metadata-only, and redacts the project identity" {
    const allocator = std.testing.allocator;
    const private_root = "/Users/author/private-site";
    const long_message = private_root ++ "/content/index.md: " ++ ("diagnostic " ** 700);
    const packet = try build(allocator, .{
        .compiler_id = "boris/0.8.1",
        .editor_id = "boris-editor/0.1.0",
        .command_mode = "ir_build",
        .failure_class = "content",
        .severity = "error",
        .code = "EFRONTMATTER",
        .message = long_message,
        .remediation = "Remove the unknown key.",
        .source_path = "index.md",
        .line = 2,
        .column = 1,
        .origin = "build_report",
        .position_confidence = "exact",
        .private_project_root = private_root,
    });
    defer allocator.free(packet);
    try std.testing.expect(packet.len <= max_packet_bytes);
    try std.testing.expect(std.mem.indexOf(u8, packet, private_root) == null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "source excerpt omitted") != null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "source: index.md") != null);
}

test "packet rejects absolute diagnostic source identities" {
    const allocator = std.testing.allocator;
    const packet = try build(allocator, .{
        .compiler_id = "boris/0.8.1",
        .editor_id = "boris-editor/0.1.0",
        .command_mode = "validate",
        .failure_class = "io",
        .severity = "error",
        .code = null,
        .message = "failed",
        .remediation = "",
        .source_path = "/private/content.md",
        .line = null,
        .column = null,
        .origin = "stderr",
        .position_confidence = "none",
        .private_project_root = "/private",
    });
    defer allocator.free(packet);
    try std.testing.expect(std.mem.indexOf(u8, packet, "/private") == null);
    try std.testing.expect(std.mem.indexOf(u8, packet, "source: <redacted>") != null);
}
