//! Standalone rendered-site search indexer. It consumes final HTML only.
const std = @import("std");
const Io = std.Io;
const search = @import("search_index");

const Options = struct {
    root: []const u8 = "dist",
    out: []const u8 = "dist/_boris/search",
    pages_file: ?[]const u8 = null,
    require_root_marker: bool = false,
    check: bool = false,
    quiet: bool = false,
};

const CliError = error{
    Help,
    MissingValue,
    UnknownFlag,
    InvalidPath,
    DuplicatePage,
    SymlinkNotAllowed,
    ReservedPage,
};

/// Boris-owned evidence namespace (#750): `_boris/**` holds proof chrome and
/// the search artifact itself. It is never searchable content, matching the
/// in-build producer, which receives an explicit page list that cannot
/// contain it.
fn isReservedNamespace(path: []const u8) bool {
    return under(path, "_boris");
}

fn usage() void {
    std.debug.print(
        "Usage: boris-search-index [OPTIONS]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --root DIR              Rendered HTML root (default: dist)\n" ++
            "  --out DIR               Search output directory (default: dist/_boris/search)\n" ++
            "  --pages-file FILE       Exact output-relative live-page list\n" ++
            "  --require-root-marker   Require data-boris-search-root on every page\n" ++
            "  --check                 Compare against existing search-index.json\n" ++
            "  --quiet, -q             Suppress the success message\n" ++
            "  --help, -h              Show this help\n",
        .{},
    );
}

fn optionValue(args: []const []const u8, index: *usize, arg: []const u8, name: []const u8) CliError![]const u8 {
    if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') {
        const value = arg[name.len + 1 ..];
        if (value.len == 0) return error.MissingValue;
        return value;
    }
    if (!std.mem.eql(u8, arg, name)) return error.UnknownFlag;
    index.* += 1;
    if (index.* >= args.len or args[index.*].len == 0) return error.MissingValue;
    return args[index.*];
}

fn parse(args: []const []const u8) CliError!Options {
    var options: Options = .{};
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return error.Help;
        }
        if (std.mem.eql(u8, arg, "--require-root-marker")) {
            options.require_root_marker = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--check")) {
            options.check = true;
            continue;
        }
        if (std.mem.eql(u8, arg, "--quiet") or std.mem.eql(u8, arg, "-q")) {
            options.quiet = true;
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--root=") or std.mem.eql(u8, arg, "--root")) {
            options.root = try optionValue(args, &i, arg, "--root");
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--out=") or std.mem.eql(u8, arg, "--out")) {
            options.out = try optionValue(args, &i, arg, "--out");
            continue;
        }
        if (std.mem.startsWith(u8, arg, "--pages-file=") or std.mem.eql(u8, arg, "--pages-file")) {
            options.pages_file = try optionValue(args, &i, arg, "--pages-file");
            continue;
        }
        return error.UnknownFlag;
    }
    return options;
}

fn under(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or
        (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == '/');
}

fn validRelative(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".") or part.len == 0) return false;
    }
    return true;
}

fn readFile(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    const file = try dir.openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size = std.math.cast(usize, stat.size) orelse return error.FileTooBig;
    var reader = file.reader(io, &.{});
    return reader.interface.readAlloc(allocator, size);
}

fn validateNoSymlink(io: Io, dir: Io.Dir, path: []const u8) !void {
    const slash = std.mem.indexOfScalar(u8, path, '/');
    const part = if (slash) |at| path[0..at] else path;
    const rest = if (slash) |at| path[at + 1 ..] else "";
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (!std.mem.eql(u8, entry.name, part)) continue;
        if (entry.kind == .sym_link) return error.SymlinkNotAllowed;
        if (rest.len == 0) {
            if (entry.kind != .file) return error.InvalidPath;
            return;
        }
        if (entry.kind != .directory) return error.InvalidPath;
        var child = try dir.openDir(io, part, .{ .iterate = true });
        defer child.close(io);
        return validateNoSymlink(io, child, rest);
    }
    return error.InvalidPath;
}

fn normalizePathSeparators(path: []u8) void {
    if (std.fs.path.sep != '/') {
        for (path) |*c| {
            if (c.* == '/') c.* = std.fs.path.sep;
        }
    }
}

fn isUnderPrefix(path: []const u8, prefix: []const u8) bool {
    return std.mem.eql(u8, path, prefix) or
        (path.len > prefix.len and std.mem.startsWith(u8, path, prefix) and path[prefix.len] == std.fs.path.sep);
}

fn trimTrailingSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and path[end - 1] == std.fs.path.sep) : (end -= 1) {}
    return path[0..end];
}

fn outputSkip(io: Io, allocator: std.mem.Allocator, root_path: []const u8, out_path: []const u8) ![]u8 {
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const root_abs = try std.fs.path.resolve(allocator, &.{ cwd, root_path });
    defer allocator.free(root_abs);
    const out_abs = try std.fs.path.resolve(allocator, &.{ cwd, out_path });
    defer allocator.free(out_abs);
    const root = trimTrailingSeparators(root_abs);
    const out = trimTrailingSeparators(out_abs);
    if (!isUnderPrefix(out, root) or std.mem.eql(u8, out, root)) return allocator.dupe(u8, "");
    const start = if (std.mem.eql(u8, root, &[_]u8{std.fs.path.sep})) 1 else root.len + 1;
    const relative = out[start..];
    const result = try allocator.dupe(u8, relative);
    normalizePathSeparators(result);
    return result;
}

fn collect(io: Io, dir: Io.Dir, prefix: []const u8, skip: []const u8, allocator: std.mem.Allocator, paths: *std.ArrayList([]const u8)) !void {
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        const relative = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        errdefer allocator.free(relative);
        if (entry.kind == .sym_link) return error.SymlinkNotAllowed;
        if (under(relative, skip) or isReservedNamespace(relative)) {
            allocator.free(relative);
            continue;
        }
        if (entry.kind == .directory) {
            var child = try dir.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            try collect(io, child, relative, skip, allocator, paths);
            allocator.free(relative);
        } else if (entry.kind == .file and std.mem.endsWith(u8, relative, ".html")) {
            try paths.append(allocator, relative);
        } else {
            allocator.free(relative);
        }
    }
}

fn sortAndRejectDuplicates(paths: []const []const u8) CliError!void {
    if (paths.len < 2) return;
    for (paths[1..], 1..) |path, index| {
        if (std.mem.eql(u8, path, paths[index - 1])) return error.DuplicatePage;
    }
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    run(init.gpa, init.io, args) catch |err| {
        if (err == error.Help) return 0;
        std.debug.print("search-index: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

fn run(allocator: std.mem.Allocator, io: Io, args: []const []const u8) !void {
    const options = parse(args) catch |err| {
        if (err != error.Help) usage();
        return err;
    };
    return runInner(allocator, io, options);
}

fn runInner(allocator: std.mem.Allocator, io: Io, options: Options) !void {
    var root = try Io.Dir.cwd().openDir(io, options.root, .{ .iterate = true });
    defer root.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }

    if (options.pages_file) |file| {
        const bytes = try readFile(io, Io.Dir.cwd(), file, allocator);
        defer allocator.free(bytes);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const path = std.mem.trim(u8, line, " \t\r");
            if (path.len == 0) continue;
            if (!validRelative(path) or !std.mem.endsWith(u8, path, ".html")) return error.InvalidPath;
            if (isReservedNamespace(path)) return error.ReservedPage;
            try validateNoSymlink(io, root, path);
            try paths.append(allocator, try allocator.dupe(u8, path));
        }
    } else {
        const skip = try outputSkip(io, allocator, options.root, options.out);
        defer allocator.free(skip);
        try collect(io, root, "", skip, allocator, &paths);
    }
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    try sortAndRejectDuplicates(paths.items);

    var documents: std.ArrayList(search.Document) = .empty;
    defer {
        for (documents.items) |document| search.freeDocument(allocator, document);
        documents.deinit(allocator);
    }
    for (paths.items) |path| {
        const html = readFile(io, root, path, allocator) catch |err| {
            std.debug.print("search-index: {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer allocator.free(html);
        const document = search.indexHtml(allocator, path, html, options.require_root_marker) catch |err| {
            std.debug.print("search-index: {s}: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        try documents.append(allocator, document);
    }
    const json = try search.writeJson(allocator, documents.items);
    defer allocator.free(json);
    const output_file = try std.fmt.allocPrint(allocator, "{s}/search-index.json", .{options.out});
    defer allocator.free(output_file);
    if (options.check) {
        const existing = readFile(io, Io.Dir.cwd(), output_file, allocator) catch return error.CheckMismatch;
        defer allocator.free(existing);
        if (!std.mem.eql(u8, existing, json)) return error.CheckMismatch;
    } else {
        var atomic = try Io.Dir.cwd().createFileAtomic(io, output_file, .{ .replace = true, .make_path = true });
        defer atomic.deinit(io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(io, &buffer);
        try writer.interface.writeAll(json);
        try writer.interface.flush();
        try atomic.replace(io);
    }
    if (!options.quiet) std.debug.print("indexed {d} rendered pages → {s}\n", .{ documents.items.len, output_file });
}

test "CLI accepts documented flag forms and returns help" {
    const args = [_][]const u8{ "boris-search-index", "--root", "site", "--out=out", "--pages-file", "pages.txt", "--quiet" };
    const options = try parse(&args);
    try std.testing.expectEqualStrings("site", options.root);
    try std.testing.expectEqualStrings("out", options.out);
    try std.testing.expectEqualStrings("pages.txt", options.pages_file.?);
    try std.testing.expect(options.quiet);
    try std.testing.expectError(error.Help, parse(&[_][]const u8{ "boris-search-index", "--help" }));
}

test "CLI rejects unsafe and duplicate page paths" {
    try std.testing.expect(!validRelative("./guide.html"));
    try std.testing.expect(!validRelative("guide/../index.html"));
    try std.testing.expectError(error.DuplicatePage, sortAndRejectDuplicates(&[_][]const u8{ "a.html", "a.html" }));
}

test "the _boris evidence namespace is reserved (#750)" {
    try std.testing.expect(isReservedNamespace("_boris"));
    try std.testing.expect(isReservedNamespace("_boris/proof/index.html"));
    try std.testing.expect(isReservedNamespace("_boris/search/search-index.json"));
    try std.testing.expect(!isReservedNamespace("boris.html"));
    try std.testing.expect(!isReservedNamespace("_borisite/index.html"));
}

test "discovery prunes _boris proof chrome from the indexed set (#750)" {
    const io = std.testing.io;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // A realistic committed target: one live page plus boris's own proof
    // viewer chrome and the search artifact beneath the output directory.
    try writeFileRel(io, tmp.dir, "index.html", "<html><body><main>Home</main></body></html>");
    try writeFileRel(io, tmp.dir, "_boris/proof/index.html", "<html><body><main>Proof</main></body></html>");
    try writeFileRel(io, tmp.dir, "_boris/search/search-index.json", "{}");

    var root = try tmp.dir.openDir(io, ".", .{ .iterate = true });
    defer root.close(io);
    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| allocator.free(path);
        paths.deinit(allocator);
    }
    try collect(io, root, "", "", allocator, &paths);
    std.mem.sort([]const u8, paths.items, {}, struct {
        fn less(_: void, left: []const u8, right: []const u8) bool {
            return std.mem.order(u8, left, right) == .lt;
        }
    }.less);
    try std.testing.expectEqual(@as(usize, 1), paths.items.len);
    try std.testing.expectEqualStrings("index.html", paths.items[0]);
}

fn writeFileRel(io: Io, dir: Io.Dir, sub_path: []const u8, data: []const u8) !void {
    const slash = std.mem.lastIndexOfScalar(u8, sub_path, '/');
    if (slash) |at| try dir.createDirPath(io, sub_path[0..at]);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = data });
}
