const std = @import("std");

pub const DependencyKind = enum {
    parent,
    layout,
    include,
    reference,
    asset,
    /// Render-only Markdown link used for incremental HTML invalidation.
    html_link,

    pub fn name(self: DependencyKind) []const u8 {
        return switch (self) {
            .parent => "parent",
            .layout => "layout",
            .include => "include",
            .reference => "reference",
            .html_link => "html-link",
            .asset => "asset",
        };
    }
};

pub const Dependency = struct {
    path: []const u8,
    kind: DependencyKind,
};

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
};
