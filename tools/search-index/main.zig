//! Standalone PR-1 rendered-site search indexer. It consumes final HTML only.
const std = @import("std");
const Io = std.Io;
const search = @import("search_index");

const Options = struct { root: []const u8 = "dist", out: []const u8 = "dist/_boris/search", pages_file: ?[]const u8 = null, require_root_marker: bool = false, check: bool = false, quiet: bool = false };
fn usage() void { std.debug.print("Usage: boris-search-index --root DIR --out DIR [--pages-file FILE] [--require-root-marker] [--check]\n", .{}); }
fn parse(args: []const []const u8) !Options { var o: Options = .{}; var i: usize = if (args.len > 0) 1 else 0; while (i < args.len) : (i += 1) { const a = args[i]; if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) { usage(); return error.Help; } if (std.mem.eql(u8, a, "--require-root-marker")) { o.require_root_marker = true; continue; } if (std.mem.eql(u8, a, "--check")) { o.check = true; continue; } if (std.mem.eql(u8, a, "--quiet") or std.mem.eql(u8, a, "-q")) { o.quiet = true; continue; } if (std.mem.startsWith(u8, a, "--root=")) o.root = a[7..] else if (std.mem.startsWith(u8, a, "--out=")) o.out = a[6..] else if (std.mem.startsWith(u8, a, "--pages-file=")) o.pages_file = a[13..] else return error.UnknownFlag; if ((std.mem.startsWith(u8, a, "--root=") and o.root.len == 0) or (std.mem.startsWith(u8, a, "--out=") and o.out.len == 0)) return error.MissingValue; } return o; }
fn under(path: []const u8, prefix: []const u8) bool { return std.mem.eql(u8, path, prefix) or (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/'); }
fn validRelative(path: []const u8) bool { if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false; var it = std.mem.splitScalar(u8, path, '/'); while (it.next()) |part| if (std.mem.eql(u8, part, "..") or part.len == 0) return false; return true; }
fn readFile(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 { const f = try dir.openFile(io, path, .{}); defer f.close(io); const stat = try f.stat(io); const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig; var reader = f.reader(io, &.{}); return reader.interface.readAlloc(a, size); }
fn collect(io: Io, dir: Io.Dir, prefix: []const u8, skip: []const u8, a: std.mem.Allocator, paths: *std.ArrayList([]const u8)) !void { var it = dir.iterate(); while (try it.next(io)) |entry| { const rel = if (prefix.len == 0) try a.dupe(u8, entry.name) else try std.fmt.allocPrint(a, "{s}/{s}", .{ prefix, entry.name }); errdefer a.free(rel); if (under(rel, skip)) { a.free(rel); continue; } if (entry.kind == .sym_link) return error.SymlinkNotAllowed; if (entry.kind == .directory) { var child = try dir.openDir(io, entry.name, .{ .iterate = true }); defer child.close(io); try collect(io, child, rel, skip, a, paths); a.free(rel); } else if (entry.kind == .file and std.mem.endsWith(u8, rel, ".html")) try paths.append(a, rel) else a.free(rel); } }
pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    run(init.gpa, init.io, args) catch |err| {
        if (err != error.Help) std.debug.print("search-index: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(a: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    const opts = parse(args) catch |err| {
        if (err != error.Help) usage();
        return err;
    };
    var root = try Io.Dir.cwd().openDir(io, opts.root, .{ .iterate = true });
    defer root.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit(a);
    }
    if (opts.pages_file) |file| {
        const bytes = try readFile(io, Io.Dir.cwd(), file, a);
        defer a.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const p = std.mem.trim(u8, line, " \t\r");
            if (p.len == 0) continue;
            if (!validRelative(p) or !std.mem.endsWith(u8, p, ".html")) return error.InvalidPath;
            try paths.append(a, try a.dupe(u8, p));
        }
    } else try collect(io, root, "", opts.out, a, &paths);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, x: []const u8, y: []const u8) bool { return std.mem.order(u8, x, y) == .lt; }
    }.less);
    var docs: std.ArrayList(search.Document) = .empty;
    defer {
        for (docs.items) |d| search.freeDocument(a, d);
        docs.deinit(a);
    }
    for (paths.items) |p| {
        const html = try readFile(io, root, p, a);
        defer a.free(html);
        try docs.append(a, try search.indexHtml(a, p, html, opts.require_root_marker));
    }
    const json = try search.writeJson(a, docs.items);
    defer a.free(json);
    const out_file = try std.fmt.allocPrint(a, "{s}/search-index.json", .{opts.out});
    defer a.free(out_file);
    if (opts.check) {
        const existing = readFile(io, Io.Dir.cwd(), out_file, a) catch return error.CheckMismatch;
        defer a.free(existing);
        if (!std.mem.eql(u8, existing, json)) return error.CheckMismatch;
    } else {
        try Io.Dir.cwd().createDirPath(io, opts.out);
        try Io.Dir.cwd().writeFile(io, .{ .sub_path = out_file, .data = json });
    }
    if (!opts.quiet) std.debug.print("indexed {d} rendered pages → {s}\n", .{ docs.items.len, out_file });
}
