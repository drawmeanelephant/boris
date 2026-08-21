const std = @import("std");
const json_out = @import("json_out.zig");
const artifact_inventory = @import("artifact_inventory.zig");
const publication_touches = @import("publication_touches.zig");

const FileBinding = publication_touches.FileBinding;
const Model = struct {
    // minimal forwarding for helpers that need model – actual Model lives in proof_pack
    // This file only provides pure helpers, not rendering
};

pub fn writeStringArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    values: []const []const u8,
    indent: usize,
) !void {
    if (values.len == 0) {
        try out.appendSlice(gpa, "[]");
        return;
    }
    try out.appendSlice(gpa, "[\n");
    for (values, 0..) |value, index| {
        try json_out.indent(out, gpa, indent + 1);
        try json_out.writeString(out, gpa, value);
        if (index + 1 < values.len) try out.append(gpa, ',');
        try out.append(gpa, '\n');
    }
    try json_out.indent(out, gpa, indent);
    try out.append(gpa, ']');
}

pub fn writeInputBlock(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    label: []const u8,
    path: []const u8,
    binding: FileBinding,
    format: []const u8,
    version: usize,
    target: []const u8,
    count_keys: []const struct { key: []const u8, value: usize },
) !void {
    try json_out.indent(out, gpa, 2);
    try json_out.writeString(out, gpa, label);
    try out.appendSlice(gpa, ": {\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"path\": ");
    try json_out.writeString(out, gpa, path);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"bytes\": ");
    try json_out.writeUsize(out, gpa, binding.bytes);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"sha256\": ");
    try json_out.writeString(out, gpa, &binding.sha256);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"format\": ");
    try json_out.writeString(out, gpa, format);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"schema_version\": ");
    try json_out.writeUsize(out, gpa, version);
    try out.appendSlice(gpa, ",\n");
    try json_out.indent(out, gpa, 3);
    try out.appendSlice(gpa, "\"target\": ");
    try json_out.writeString(out, gpa, target);
    for (count_keys) |count_key| {
        try out.appendSlice(gpa, ",\n");
        try json_out.indent(out, gpa, 3);
        try json_out.writeString(out, gpa, count_key.key);
        try out.appendSlice(gpa, ": ");
        try json_out.writeUsize(out, gpa, count_key.value);
    }
    try out.appendSlice(gpa, "\n");
    try json_out.indent(out, gpa, 2);
    try out.append(gpa, '}');
}

pub fn stripPrefix(value: []const u8, prefix: []const u8) []const u8 {
    if (std.mem.startsWith(u8, value, prefix)) return value[prefix.len..];
    return value;
}

pub fn writeRelationArray(
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    label: []const u8,
    values: []const []const u8,
) !void {
    try json_out.indent(out, gpa, 3);
    try json_out.writeString(out, gpa, label);
    try out.appendSlice(gpa, ": ");
    try writeStringArray(out, gpa, values, 3);
}
