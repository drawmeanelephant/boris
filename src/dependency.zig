const std = @import("std");
const json_out = @import("json_out.zig");

pub const DependencyKind = enum {
    parent,
    layout,
    include,
    reference,
    asset,

    pub fn name(self: DependencyKind) []const u8 {
        return switch (self) {
            .parent => "parent",
            .layout => "layout",
            .include => "include",
            .reference => "reference",
            .asset => "asset",
        };
    }
};

pub const Dependency = struct {
    path: []const u8,
    kind: DependencyKind,
};

pub fn compareDependency(_: void, a: Dependency, b: Dependency) bool {
    const cmp = std.mem.order(u8, a.path, b.path);
    if (cmp != .eq) {
        return cmp == .lt;
    }
    return @intFromEnum(a.kind) < @intFromEnum(b.kind);
}

pub fn compareStrings(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

pub const DependencyIndex = struct {
    allocator: std.mem.Allocator,
    forward: std.StringHashMapUnmanaged(std.ArrayList(Dependency)),
    reverse: std.StringHashMapUnmanaged(std.ArrayList(Dependency)),

    pub fn init(allocator: std.mem.Allocator) DependencyIndex {
        return .{
            .allocator = allocator,
            .forward = .{},
            .reverse = .{},
        };
    }

    pub fn deinit(self: *DependencyIndex) void {
        var fw_it = self.forward.iterator();
        while (fw_it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit(self.allocator);
        }
        self.forward.deinit(self.allocator);

        var rv_it = self.reverse.iterator();
        while (rv_it.next()) |entry| {
            var list = entry.value_ptr.*;
            list.deinit(self.allocator);
        }
        self.reverse.deinit(self.allocator);
    }

    pub fn addDependency(self: *DependencyIndex, source: []const u8, target: []const u8, kind: DependencyKind) !void {
        // Add to forward map
        var fw_entry = try self.forward.getOrPut(self.allocator, source);
        if (!fw_entry.found_existing) {
            fw_entry.value_ptr.* = .empty;
        }
        // Avoid duplicates
        var exists = false;
        for (fw_entry.value_ptr.items) |dep| {
            if (std.mem.eql(u8, dep.path, target) and dep.kind == kind) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try fw_entry.value_ptr.append(self.allocator, .{ .path = target, .kind = kind });
        }

        // Add to reverse map
        var rv_entry = try self.reverse.getOrPut(self.allocator, target);
        if (!rv_entry.found_existing) {
            rv_entry.value_ptr.* = .empty;
        }
        exists = false;
        for (rv_entry.value_ptr.items) |dep| {
            if (std.mem.eql(u8, dep.path, source) and dep.kind == kind) {
                exists = true;
                break;
            }
        }
        if (!exists) {
            try rv_entry.value_ptr.append(self.allocator, .{ .path = source, .kind = kind });
        }
    }

    pub fn renderJson(self: *DependencyIndex, gpa: std.mem.Allocator) ![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        errdefer buf.deinit(gpa);

        try buf.appendSlice(gpa, "{\n");
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"schemaVersion\": \"0.1.0\",\n");

        // --- 1. Render Forward Index -------------------------------------------
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"forward\": {\n");

        // Get sorted list of forward source keys
        var fw_keys: std.ArrayList([]const u8) = .empty;
        defer fw_keys.deinit(gpa);
        var fw_it = self.forward.iterator();
        while (fw_it.next()) |entry| {
            try fw_keys.append(gpa, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, fw_keys.items, {}, compareStrings);

        for (fw_keys.items, 0..) |src, src_idx| {
            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, '"');
            try buf.appendSlice(gpa, src);
            try buf.appendSlice(gpa, "\": [\n");

            const list = self.forward.getPtr(src).?;
            std.mem.sort(Dependency, list.items, {}, compareDependency);

            for (list.items, 0..) |dep, dep_idx| {
                try json_out.indent(&buf, gpa, 3);
                try buf.appendSlice(gpa, "{\n");

                try json_out.indent(&buf, gpa, 4);
                try buf.appendSlice(gpa, "\"target\": ");
                try json_out.writeString(&buf, gpa, dep.path);
                try buf.appendSlice(gpa, ",\n");

                try json_out.indent(&buf, gpa, 4);
                try buf.appendSlice(gpa, "\"kind\": ");
                try json_out.writeString(&buf, gpa, dep.kind.name());
                try buf.append(gpa, '\n');

                try json_out.indent(&buf, gpa, 3);
                try buf.append(gpa, '}');
                if (dep_idx + 1 < list.items.len) try buf.append(gpa, ',');
                try buf.append(gpa, '\n');
            }

            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, ']');
            if (src_idx + 1 < fw_keys.items.len) try buf.append(gpa, ',');
            try buf.append(gpa, '\n');
        }

        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "},\n");

        // --- 2. Render Reverse Index -------------------------------------------
        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "\"reverse\": {\n");

        // Get sorted list of reverse target keys
        var rv_keys: std.ArrayList([]const u8) = .empty;
        defer rv_keys.deinit(gpa);
        var rv_it = self.reverse.iterator();
        while (rv_it.next()) |entry| {
            try rv_keys.append(gpa, entry.key_ptr.*);
        }
        std.mem.sort([]const u8, rv_keys.items, {}, compareStrings);

        for (rv_keys.items, 0..) |tgt, tgt_idx| {
            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, '"');
            try buf.appendSlice(gpa, tgt);
            try buf.appendSlice(gpa, "\": [\n");

            const list = self.reverse.getPtr(tgt).?;
            std.mem.sort(Dependency, list.items, {}, compareDependency);

            for (list.items, 0..) |dep, dep_idx| {
                try json_out.indent(&buf, gpa, 3);
                try buf.appendSlice(gpa, "{\n");

                try json_out.indent(&buf, gpa, 4);
                try buf.appendSlice(gpa, "\"source\": ");
                try json_out.writeString(&buf, gpa, dep.path);
                try buf.appendSlice(gpa, ",\n");

                try json_out.indent(&buf, gpa, 4);
                try buf.appendSlice(gpa, "\"kind\": ");
                try json_out.writeString(&buf, gpa, dep.kind.name());
                try buf.append(gpa, '\n');

                try json_out.indent(&buf, gpa, 3);
                try buf.append(gpa, '}');
                if (dep_idx + 1 < list.items.len) try buf.append(gpa, ',');
                try buf.append(gpa, '\n');
            }

            try json_out.indent(&buf, gpa, 2);
            try buf.append(gpa, ']');
            if (tgt_idx + 1 < rv_keys.items.len) try buf.append(gpa, ',');
            try buf.append(gpa, '\n');
        }

        try json_out.indent(&buf, gpa, 1);
        try buf.appendSlice(gpa, "}\n");

        try buf.appendSlice(gpa, "}\n");
        return try buf.toOwnedSlice(gpa);
    }
};

test "DependencyIndex basic adding and rendering" {
    const gpa = std.testing.allocator;
    var idx = DependencyIndex.init(gpa);
    defer idx.deinit();

    try idx.addDependency("guides/intro", "layouts/main.html", .layout);
    try idx.addDependency("guides/intro", "guides/install", .reference);
    try idx.addDependency("guides/intro", "assets/logo.png", .asset);

    try idx.addDependency("guides/install", "layouts/main.html", .layout);
    try idx.addDependency("guides/install", "guides/intro", .parent);

    const json = try idx.renderJson(gpa);
    defer gpa.free(json);

    // Assert format is correct and fields are present
    try std.testing.expect(std.mem.indexOf(u8, json, "\"schemaVersion\": \"0.1.0\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"forward\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"reverse\"") != null);
}
