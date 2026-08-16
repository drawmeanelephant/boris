//! Read-only Boris project discovery. Conventional project files remain the
//! only authority; the editor never creates or consults a second manifest.

const std = @import("std");
const Io = std.Io;

pub const InputMode = enum { markdown, cooklang, textile, mixed, empty };

pub const Discovery = struct {
    content: bool,
    default_layout: bool,
    publication_profile: bool,
    input_mode: InputMode = .empty,

    pub fn isProject(self: Discovery) bool {
        return self.content;
    }
};

pub fn discover(io: Io, project_root: []const u8) !Discovery {
    var root = try Io.Dir.cwd().openDir(io, project_root, .{ .iterate = true, .follow_symlinks = false });
    defer root.close(io);
    return .{
        .content = isDirectory(io, root, "content"),
        .default_layout = isFile(io, root, "themes/boris/layouts/main.html"),
        .publication_profile = isFile(io, root, "boris.json"),
        .input_mode = detectInputMode(io, root),
    };
}

/// Page-extension scan only. The editor does not parse Cooklang, Textile, or Markdown.
pub fn detectInputMode(io: Io, root: Io.Dir) InputMode {
    var saw_markdown = false;
    var saw_cooklang = false;
    var saw_textile = false;
    scanPages(io, root, "content", &saw_markdown, &saw_cooklang, &saw_textile);
    if (saw_cooklang and !saw_markdown and !saw_textile) return .cooklang;
    if (saw_textile and !saw_markdown and !saw_cooklang) return .textile;
    if (saw_markdown and !saw_cooklang and !saw_textile) return .markdown;
    if (!saw_markdown and !saw_cooklang and !saw_textile) return .empty;
    return .mixed;
}

fn scanPages(io: Io, root: Io.Dir, rel: []const u8, saw_markdown: *bool, saw_cooklang: *bool, saw_textile: *bool) void {
    var dir = root.openDir(io, rel, .{ .iterate = true, .follow_symlinks = false }) catch return;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
                var child: [4096]u8 = undefined;
                const path = std.fmt.bufPrint(&child, "{s}/{s}", .{ rel, entry.name }) catch continue;
                scanPages(io, root, path, saw_markdown, saw_cooklang, saw_textile);
            },
            .file => {
                if (std.mem.endsWith(u8, entry.name, ".cook")) saw_cooklang.* = true;
                if (std.mem.endsWith(u8, entry.name, ".textile")) saw_textile.* = true;
                if (std.mem.endsWith(u8, entry.name, ".md") or std.mem.endsWith(u8, entry.name, ".mdx")) saw_markdown.* = true;
            },
            else => {},
        }
    }
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
    var temp = std.testing.tmpDir(.{});
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
    try std.testing.expectEqual(InputMode.empty, found.input_mode);
}

test "input mode is a page-extension scan of content/" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var temp = std.testing.tmpDir(.{});
    defer temp.cleanup();
    try temp.dir.createDirPath(io, "content/sauces");
    const path = try temp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(path);

    try temp.dir.writeFile(io, .{ .sub_path = "content/index.cook", .data = "---\nid: index\n---\n" });
    try temp.dir.writeFile(io, .{ .sub_path = "content/sauces/oil.cook", .data = "---\nid: sauces/oil\n---\n" });
    try std.testing.expectEqual(InputMode.cooklang, (try discover(io, path)).input_mode);

    try temp.dir.writeFile(io, .{ .sub_path = "content/notes.md", .data = "# note\n" });
    try std.testing.expectEqual(InputMode.mixed, (try discover(io, path)).input_mode);
}
