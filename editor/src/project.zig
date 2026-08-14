//! Read-only Boris project discovery. Conventional project files remain the
//! only authority; the editor never creates or consults a second manifest.

const std = @import("std");
const Io = std.Io;

pub const Discovery = struct {
    content: bool,
    default_layout: bool,
    publication_profile: bool,

    pub fn isProject(self: Discovery) bool {
        return self.content;
    }
};

pub fn discover(io: Io, project_root: []const u8) !Discovery {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{});
    defer root.close(io);
    return .{
        .content = isDirectory(io, root, "content"),
        .default_layout = isFile(io, root, "themes/boris/layouts/main.html"),
        .publication_profile = isFile(io, root, "boris.json"),
    };
}

fn isDirectory(io: Io, dir: Io.Dir, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .directory;
}

fn isFile(io: Io, dir: Io.Dir, path: []const u8) bool {
    const stat = dir.statFile(io, path, .{}) catch return false;
    return stat.kind == .file;
}

test "project discovery uses Boris conventions without writing" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = try std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "content");
    try temp.dir.createDirPath(io, "themes/boris/layouts");
    try temp.dir.writeFile(io, .{ .sub_path = "themes/boris/layouts/main.html", .data = "{{content}}" });
    try temp.dir.writeFile(io, .{ .sub_path = "boris.json", .data = "{}" });
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    const found = try discover(io, path);
    try std.testing.expect(found.isProject());
    try std.testing.expect(found.default_layout);
    try std.testing.expect(found.publication_profile);
}
