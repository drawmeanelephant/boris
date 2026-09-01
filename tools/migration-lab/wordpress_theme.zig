//! WordPress theme archaeology laboratory — static, read-only PHP theme scan.
//!
//! This is deliberately not a PHP parser or WordPress compatibility layer. It
//! classifies filenames and scans source lines for well-known template tags and
//! hooks. PHP is never executed, remote assets are never fetched, and every
//! dynamic finding is retained in manual_review.json.

const std = @import("std");
const Io = std.Io;
const publication = @import("publication.zig");
const product_boris = @import("product_boris.zig");

pub const format_id = "boris-wordpress-theme-archaeology-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const Options = struct {
    root_dir: []const u8,
    out_dir: []const u8,
    quiet: bool = false,
};

pub const LabError = error{ OutputInsideSource, SourceNotFound, OutOfMemory, IoFailure };

pub const Decision = enum {
    preserve,
    adapt,
    review,
    drop,

    pub fn jsonName(self: Decision) []const u8 {
        return switch (self) {
            .preserve => "preserve",
            .adapt => "adapt",
            .review => "review",
            .drop => "drop",
        };
    }
};

pub const TemplateKind = enum {
    index,
    single,
    page,
    home,
    archive,
    category,
    tag,
    author,
    date,
    search,
    not_found,
    header,
    footer,
    sidebar,
    comments,
    search_form,
    functions,
    stylesheet,
    theme_json,
    block_template,
    generic_php,
    asset,
    other,

    pub fn jsonName(self: TemplateKind) []const u8 {
        return switch (self) {
            .index => "index",
            .single => "single",
            .page => "page",
            .home => "home",
            .archive => "archive",
            .category => "category",
            .tag => "tag",
            .author => "author",
            .date => "date",
            .search => "search",
            .not_found => "404",
            .header => "header",
            .footer => "footer",
            .sidebar => "sidebar",
            .comments => "comments",
            .search_form => "search_form",
            .functions => "functions",
            .stylesheet => "stylesheet",
            .theme_json => "theme_json",
            .block_template => "block_template",
            .generic_php => "generic_php",
            .asset => "asset",
            .other => "other",
        };
    }
};

/// Closed filename classifier used by tests and the deterministic inventory.
pub fn classifyTemplate(path: []const u8) TemplateKind {
    const base = std.fs.path.basename(path);
    if (std.mem.eql(u8, path, "theme.json")) return .theme_json;
    if (isBlockTemplatePath(path)) return .block_template;
    if (std.ascii.eqlIgnoreCase(base, "style.css")) return .stylesheet;
    if (!std.mem.endsWith(u8, base, ".php")) {
        if (isAssetPath(path)) return .asset;
        return .other;
    }
    const stem = base[0 .. base.len - 4];
    if (std.ascii.eqlIgnoreCase(stem, "index")) return .index;
    if (std.ascii.eqlIgnoreCase(stem, "single")) return .single;
    if (std.ascii.eqlIgnoreCase(stem, "page")) return .page;
    if (std.ascii.eqlIgnoreCase(stem, "home")) return .home;
    if (std.ascii.eqlIgnoreCase(stem, "archive")) return .archive;
    if (std.ascii.eqlIgnoreCase(stem, "category")) return .category;
    if (std.ascii.eqlIgnoreCase(stem, "tag")) return .tag;
    if (std.ascii.eqlIgnoreCase(stem, "author")) return .author;
    if (std.ascii.eqlIgnoreCase(stem, "date")) return .date;
    if (std.ascii.eqlIgnoreCase(stem, "search")) return .search;
    if (std.ascii.eqlIgnoreCase(stem, "404")) return .not_found;
    if (std.ascii.eqlIgnoreCase(stem, "header")) return .header;
    if (std.ascii.eqlIgnoreCase(stem, "footer")) return .footer;
    if (std.ascii.eqlIgnoreCase(stem, "sidebar")) return .sidebar;
    if (std.ascii.eqlIgnoreCase(stem, "comments")) return .comments;
    if (std.ascii.eqlIgnoreCase(stem, "searchform") or std.ascii.eqlIgnoreCase(stem, "search-form")) return .search_form;
    if (std.ascii.eqlIgnoreCase(stem, "functions")) return .functions;
    return .generic_php;
}

fn isBlockTemplatePath(path: []const u8) bool {
    const prefix = "templates/";
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    const name = path[prefix.len..];
    return name.len > 0 and std.mem.indexOfScalar(u8, name, '/') == null and std.mem.endsWith(u8, name, ".html");
}

fn isAssetPath(path: []const u8) bool {
    const ext = fileExtension(path);
    return std.ascii.eqlIgnoreCase(ext, ".css") or std.ascii.eqlIgnoreCase(ext, ".js") or
        std.ascii.eqlIgnoreCase(ext, ".mjs") or std.ascii.eqlIgnoreCase(ext, ".png") or
        std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg") or
        std.ascii.eqlIgnoreCase(ext, ".gif") or std.ascii.eqlIgnoreCase(ext, ".svg") or
        std.ascii.eqlIgnoreCase(ext, ".webp") or std.ascii.eqlIgnoreCase(ext, ".ico") or
        std.ascii.eqlIgnoreCase(ext, ".woff") or std.ascii.eqlIgnoreCase(ext, ".woff2") or
        std.ascii.eqlIgnoreCase(ext, ".ttf") or std.ascii.eqlIgnoreCase(ext, ".otf");
}

fn fileExtension(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    if (dot == 0) return "";
    return base[dot..];
}

fn isText(path: []const u8) bool {
    const ext = fileExtension(path);
    return std.ascii.eqlIgnoreCase(ext, ".php") or std.ascii.eqlIgnoreCase(ext, ".css") or
        std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs") or
        std.ascii.eqlIgnoreCase(ext, ".txt") or std.ascii.eqlIgnoreCase(ext, ".md");
}

fn fileDecision(path: []const u8) Decision {
    const kind = classifyTemplate(path);
    if (kind == .stylesheet or kind == .asset or kind == .theme_json or kind == .block_template) {
        const ext = fileExtension(path);
        if (std.ascii.eqlIgnoreCase(ext, ".js") or std.ascii.eqlIgnoreCase(ext, ".mjs")) return .drop;
        return .preserve;
    }
    if (std.mem.endsWith(u8, path, ".php")) return .review;
    return .review;
}

fn isSkippedDir(name: []const u8) bool {
    return std.mem.eql(u8, name, ".git") or std.mem.eql(u8, name, "node_modules") or
        std.mem.eql(u8, name, "dist") or std.mem.eql(u8, name, "zig-out") or
        std.mem.eql(u8, name, ".zig-cache") or std.mem.eql(u8, name, "migration-report");
}

fn joinRel(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return try a.dupe(u8, name);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, a: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(a, .unlimited);
}

fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const out = try a.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        out[i * 2] = hex[byte >> 4];
        out[i * 2 + 1] = hex[byte & 15];
    }
    return out;
}

const FileRec = struct {
    path: []const u8,
    bytes: usize,
    sha256: []const u8,
};

const Signal = struct {
    source_path: []const u8,
    line: usize,
    category: []const u8,
    name: []const u8,
    evidence: []const u8,
    proposed: []const u8,
    decision: Decision,
    unsupported: bool,
};

fn walkTree(io: Io, a: std.mem.Allocator, root: Io.Dir, rel: []const u8, files: *std.ArrayList(FileRec)) !void {
    var dir = root.openDir(io, if (rel.len == 0) "." else rel, .{ .iterate = true }) catch |err| {
        if (rel.len == 0) return err;
        return;
    };
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        if (entry.kind == .directory) {
            if (isSkippedDir(entry.name)) continue;
            const child = try joinRel(a, rel, entry.name);
            try walkTree(io, a, root, child, files);
            continue;
        }
        if (entry.kind != .file) continue;
        const path = try joinRel(a, rel, entry.name);
        const data = readFileAlloc(io, root, path, a) catch continue;
        try files.append(a, .{ .path = path, .bytes = data.len, .sha256 = try sha256Hex(a, data) });
    }
}

fn isIdent(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
}

fn hasCall(line: []const u8, name: []const u8) bool {
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, line, pos, name)) |at| {
        const before_ok = at == 0 or !isIdent(line[at - 1]);
        var after = at + name.len;
        while (after < line.len and (line[after] == ' ' or line[after] == '\t')) after += 1;
        if (before_ok and after < line.len and line[after] == '(') return true;
        pos = at + name.len;
    }
    return false;
}

fn firstQuoted(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\'' and line[i] != '"') continue;
        const q = line[i];
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, q) orelse return "";
        return try a.dupe(u8, line[start..end]);
    }
    return "";
}

fn valueAfterKey(a: std.mem.Allocator, line: []const u8, key: []const u8) ![]const u8 {
    const key_at = std.mem.indexOf(u8, line, key) orelse return "";
    const arrow_at = std.mem.indexOfPos(u8, line, key_at + key.len, "=>") orelse return "";
    var i = arrow_at + 2;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    if (i >= line.len or (line[i] != '\'' and line[i] != '"')) return "";
    const quote = line[i];
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, line, start, quote) orelse return "";
    return try a.dupe(u8, line[start..end]);
}

fn mapKeys(a: std.mem.Allocator, line: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\'' and line[i] != '"') continue;
        const quote = line[i];
        const start = i + 1;
        const end = std.mem.indexOfScalarPos(u8, line, start, quote) orelse break;
        var after = end + 1;
        while (after < line.len and (line[after] == ' ' or line[after] == '\t')) after += 1;
        if (after + 1 < line.len and line[after] == '=' and line[after + 1] == '>') {
            if (out.items.len > 0) try out.append(a, ',');
            try out.appendSlice(a, line[start..end]);
        }
        i = end;
    }
    return try out.toOwnedSlice(a);
}

fn addSignal(a: std.mem.Allocator, signals: *std.ArrayList(Signal), path: []const u8, line_no: usize, category: []const u8, name: []const u8, evidence: []const u8, proposed: []const u8, decision: Decision, unsupported: bool) !void {
    try signals.append(a, .{
        .source_path = path,
        .line = line_no,
        .category = category,
        .name = name,
        .evidence = try a.dupe(u8, evidence),
        .proposed = proposed,
        .decision = decision,
        .unsupported = unsupported,
    });
}

const CallRule = struct {
    call: []const u8,
    category: []const u8,
    decision: Decision,
    proposed: []const u8,
    unsupported: bool,
};

const call_rules = [_]CallRule{
    .{ .call = "get_header", .category = "template_relationship", .decision = .adapt, .proposed = "header shell → theme/layouts/main.html", .unsupported = false },
    .{ .call = "get_footer", .category = "template_relationship", .decision = .adapt, .proposed = "footer shell → {{footer}}", .unsupported = false },
    .{ .call = "get_sidebar", .category = "template_relationship", .decision = .review, .proposed = "sidebar → nav/children/toc/Aside design review", .unsupported = true },
    .{ .call = "get_template_part", .category = "template_relationship", .decision = .review, .proposed = "manual template-part decomposition", .unsupported = true },
    .{ .call = "get_search_form", .category = "template_relationship", .decision = .review, .proposed = "searchform.php is outside the static docs prototype", .unsupported = true },
    .{ .call = "comments_template", .category = "dynamic", .decision = .review, .proposed = "comments are outside the static docs prototype", .unsupported = true },
    .{ .call = "wp_nav_menu", .category = "menu", .decision = .adapt, .proposed = "menu location → {{nav}} after graph review", .unsupported = true },
    .{ .call = "register_nav_menus", .category = "menu", .decision = .review, .proposed = "rebuild locations from the Boris graph", .unsupported = true },
    .{ .call = "register_nav_menu", .category = "menu", .decision = .review, .proposed = "rebuild location from the Boris graph", .unsupported = true },
    .{ .call = "register_sidebar", .category = "widget", .decision = .review, .proposed = "review widget content; no PHP widget runtime", .unsupported = true },
    .{ .call = "register_sidebars", .category = "widget", .decision = .review, .proposed = "review widget content; no PHP widget runtime", .unsupported = true },
    .{ .call = "dynamic_sidebar", .category = "widget", .decision = .review, .proposed = "sidebar widgets require static HTML/content design", .unsupported = true },
    .{ .call = "is_active_sidebar", .category = "widget", .decision = .review, .proposed = "widget visibility is WordPress runtime state", .unsupported = true },
    .{ .call = "wp_list_pages", .category = "navigation", .decision = .adapt, .proposed = "page hierarchy → {{children}} or {{nav}}", .unsupported = true },
    .{ .call = "wp_list_categories", .category = "navigation", .decision = .review, .proposed = "taxonomy navigation requires explicit content model", .unsupported = true },
    .{ .call = "have_posts", .category = "loop", .decision = .adapt, .proposed = "one Boris page per resolved document", .unsupported = true },
    .{ .call = "the_post", .category = "loop", .decision = .adapt, .proposed = "one Boris page per resolved document", .unsupported = true },
    .{ .call = "the_title", .category = "content_slot", .decision = .adapt, .proposed = "{{title}}", .unsupported = false },
    .{ .call = "the_content", .category = "content_slot", .decision = .adapt, .proposed = "{{content}}", .unsupported = false },
    .{ .call = "the_excerpt", .category = "content_slot", .decision = .review, .proposed = "excerpt policy is not inferred", .unsupported = true },
    .{ .call = "wp_title", .category = "content_slot", .decision = .adapt, .proposed = "legacy title tag → {{title}} after metadata review", .unsupported = true },
    .{ .call = "bloginfo", .category = "site_metadata", .decision = .review, .proposed = "site metadata requires explicit static values", .unsupported = true },
    .{ .call = "language_attributes", .category = "site_metadata", .decision = .review, .proposed = "static language attribute only after site policy review", .unsupported = true },
    .{ .call = "body_class", .category = "runtime", .decision = .review, .proposed = "conditional body classes are not inferred", .unsupported = true },
    .{ .call = "post_class", .category = "runtime", .decision = .review, .proposed = "conditional post classes are not inferred", .unsupported = true },
    .{ .call = "the_ID", .category = "runtime", .decision = .review, .proposed = "WordPress post ids are not Boris entity ids", .unsupported = true },
    .{ .call = "the_author", .category = "site_metadata", .decision = .review, .proposed = "author metadata is preserved only by explicit content policy", .unsupported = true },
    .{ .call = "the_date", .category = "site_metadata", .decision = .review, .proposed = "date metadata is not inferred into frontmatter", .unsupported = true },
    .{ .call = "get_search_query", .category = "dynamic", .decision = .drop, .proposed = "server-side search state has no static prototype equivalent", .unsupported = true },
    .{ .call = "get_stylesheet_uri", .category = "asset_reference", .decision = .adapt, .proposed = "local style.css → theme/assets/css/**", .unsupported = false },
    .{ .call = "get_template_directory_uri", .category = "asset_reference", .decision = .review, .proposed = "resolve local asset path manually; no PHP URI runtime", .unsupported = true },
    .{ .call = "wp_head", .category = "hook", .decision = .review, .proposed = "static head only; inspect registered callbacks", .unsupported = true },
    .{ .call = "wp_footer", .category = "hook", .decision = .review, .proposed = "static footer only; inspect registered callbacks", .unsupported = true },
    .{ .call = "add_action", .category = "hook", .decision = .review, .proposed = "preserve callback name for manual redesign", .unsupported = true },
    .{ .call = "add_filter", .category = "hook", .decision = .review, .proposed = "preserve callback name for manual redesign", .unsupported = true },
    .{ .call = "apply_filters", .category = "hook", .decision = .review, .proposed = "filter semantics require human port", .unsupported = true },
    .{ .call = "do_action", .category = "hook", .decision = .review, .proposed = "action semantics require human port", .unsupported = true },
    .{ .call = "wp_enqueue_script", .category = "runtime", .decision = .drop, .proposed = "no Boris JS runtime in prototype", .unsupported = true },
    .{ .call = "wp_enqueue_style", .category = "asset_reference", .decision = .adapt, .proposed = "local CSS → theme/assets/**", .unsupported = false },
    .{ .call = "comments_open", .category = "dynamic", .decision = .review, .proposed = "comments require an external/static policy", .unsupported = true },
    .{ .call = "wp_list_comments", .category = "dynamic", .decision = .review, .proposed = "comments are outside the static docs prototype", .unsupported = true },
    .{ .call = "comment_form", .category = "dynamic", .decision = .drop, .proposed = "no server-side comment form", .unsupported = true },
};

fn scanPhp(a: std.mem.Allocator, path: []const u8, data: []const u8, signals: *std.ArrayList(Signal)) !void {
    var pos: usize = 0;
    var line_no: usize = 1;
    while (pos <= data.len) : (line_no += 1) {
        const end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..end];
        for (call_rules) |rule| {
            if (!hasCall(line, rule.call)) continue;
            const label = if (std.mem.eql(u8, rule.call, "register_nav_menus"))
                (try mapKeys(a, line))
            else if (std.mem.eql(u8, rule.call, "wp_nav_menu"))
                (try valueAfterKey(a, line, "theme_location"))
            else if (std.mem.eql(u8, rule.call, "register_sidebar"))
                (try valueAfterKey(a, line, "'id'"))
            else if (std.mem.eql(u8, rule.category, "menu") or std.mem.eql(u8, rule.category, "widget") or std.mem.eql(u8, rule.category, "hook"))
                (try firstQuoted(a, line))
            else
                "";
            const name = if (label.len > 0) try std.fmt.allocPrint(a, "{s}:{s}", .{ rule.call, label }) else rule.call;
            try addSignal(a, signals, path, line_no, rule.category, name, line, rule.proposed, rule.decision, rule.unsupported);
        }
        if (hasCall(line, "include") or hasCall(line, "require") or hasCall(line, "require_once")) {
            try addSignal(a, signals, path, line_no, "dynamic", "php_include", line, "included PHP must be manually flattened or dropped", .review, true);
        }
        if (std.mem.indexOf(u8, line, "<?php") != null or std.mem.indexOf(u8, line, "<?=") != null) {
            // The evidence line is retained by the specific calls above; this
            // broad marker makes PHP presence visible even for unknown code.
            if (std.mem.indexOf(u8, line, "<?php") != null and line.len > 6) {
                try addSignal(a, signals, path, line_no, "php", "php_code", line, "no automatic PHP translation", .review, true);
            }
        }
        if (end == data.len) break;
        pos = end + 1;
    }
}

fn scanStyle(a: std.mem.Allocator, path: []const u8, data: []const u8, signals: *std.ArrayList(Signal)) !void {
    var pos: usize = 0;
    var line_no: usize = 1;
    while (pos <= data.len) : (line_no += 1) {
        const end = std.mem.indexOfScalarPos(u8, data, pos, '\n') orelse data.len;
        const line = data[pos..end];
        const keys = [_][]const u8{ "Theme Name:", "Theme URI:", "Author:", "Version:", "Template:" };
        for (keys) |key| {
            if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t\r"), key)) {
                try addSignal(a, signals, path, line_no, "provenance", key[0 .. key.len - 1], line, "preserve in migration provenance", .preserve, false);
            }
        }
        if (end == data.len) break;
        pos = end + 1;
    }
}

fn signalLess(_: void, x: Signal, y: Signal) bool {
    const p = std.mem.order(u8, x.source_path, y.source_path);
    if (p != .eq) return p == .lt;
    if (x.line != y.line) return x.line < y.line;
    const c = std.mem.order(u8, x.category, y.category);
    if (c != .eq) return c == .lt;
    return std.mem.order(u8, x.name, y.name) == .lt;
}

fn fileLess(_: void, x: FileRec, y: FileRec) bool {
    return std.mem.order(u8, x.path, y.path) == .lt;
}

fn ensureParent(io: Io, root: Io.Dir, rel: []const u8) !void {
    if (std.fs.path.dirname(rel)) |parent| if (parent.len > 0) try root.createDirPath(io, parent);
}

fn writeBytes(io: Io, root: Io.Dir, rel: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel);
    try root.writeFile(io, .{ .sub_path = rel, .data = data });
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try buf.appendSlice(a, "\\\""),
        '\\' => try buf.appendSlice(a, "\\\\"),
        '\n' => try buf.appendSlice(a, "\\n"),
        '\r' => try buf.appendSlice(a, "\\r"),
        '\t' => try buf.appendSlice(a, "\\t"),
        else => if (c < 0x20) {
            var tmp: [6]u8 = undefined;
            try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c}));
        } else try buf.append(a, c),
    };
    try buf.append(a, '"');
}

fn appendUsize(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: usize) !void {
    var tmp: [32]u8 = undefined;
    try buf.appendSlice(a, try std.fmt.bufPrint(&tmp, "{d}", .{n}));
}

fn appendBool(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(a, if (v) "true" else "false");
}

fn countSignals(signals: []const Signal, category: []const u8) usize {
    var n: usize = 0;
    for (signals) |s| {
        if (std.mem.eql(u8, s.category, category)) n += 1;
    }
    return n;
}

fn countFiles(files: []const FileRec, kind: TemplateKind) usize {
    var n: usize = 0;
    for (files) |file| {
        if (classifyTemplate(file.path) == kind) n += 1;
    }
    return n;
}

fn emitInventory(a: std.mem.Allocator, root: []const u8, files: []const FileRec, signals: []const Signal) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\n  \"format\": ");
    try appendJson(&b, a, format_id);
    try b.appendSlice(a, ",\n  \"schema_version\": 1,\n  \"tool_version\": ");
    try appendJson(&b, a, tool_version);
    try b.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&b, a, root);
    try b.appendSlice(a, ",\n  \"policy\": { \"execute_php\": false, \"remote_fetch\": false, \"source_readonly\": true },\n  \"files\": [\n");
    for (files, 0..) |f, i| {
        try b.appendSlice(a, "    { \"path\": ");
        try appendJson(&b, a, f.path);
        try b.appendSlice(a, ", \"bytes\": ");
        try appendUsize(&b, a, f.bytes);
        try b.appendSlice(a, ", \"sha256\": ");
        try appendJson(&b, a, f.sha256);
        try b.appendSlice(a, ", \"template_kind\": ");
        try appendJson(&b, a, classifyTemplate(f.path).jsonName());
        try b.appendSlice(a, ", \"decision\": ");
        try appendJson(&b, a, fileDecision(f.path).jsonName());
        try b.appendSlice(a, " }");
        if (i + 1 < files.len) try b.append(a, ',');
        try b.append(a, '\n');
    }
    try b.appendSlice(a, "  ],\n  \"block_theme_evidence\": [\n");
    var first_block = true;
    for (files) |file| {
        const kind = classifyTemplate(file.path);
        if (kind != .theme_json and kind != .block_template) continue;
        if (!first_block) try b.appendSlice(a, ",\n");
        first_block = false;
        try b.appendSlice(a, "    { \"kind\": ");
        try appendJson(&b, a, kind.jsonName());
        try b.appendSlice(a, ", \"source_path\": ");
        try appendJson(&b, a, file.path);
        try b.appendSlice(a, ", \"bytes\": ");
        try appendUsize(&b, a, file.bytes);
        try b.appendSlice(a, ", \"sha256\": ");
        try appendJson(&b, a, file.sha256);
        try b.appendSlice(a, ", \"decision\": \"preserve\", \"scope\": \"static inventory only\" }");
    }
    try b.appendSlice(a, "\n  ],\n  \"signals\": [\n");
    for (signals, 0..) |s, i| {
        try b.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&b, a, s.source_path);
        try b.appendSlice(a, ", \"line\": ");
        try appendUsize(&b, a, s.line);
        try b.appendSlice(a, ", \"category\": ");
        try appendJson(&b, a, s.category);
        try b.appendSlice(a, ", \"name\": ");
        try appendJson(&b, a, s.name);
        try b.appendSlice(a, ", \"evidence\": ");
        try appendJson(&b, a, s.evidence);
        try b.appendSlice(a, ", \"proposed_boris_equivalent\": ");
        try appendJson(&b, a, s.proposed);
        try b.appendSlice(a, ", \"decision\": ");
        try appendJson(&b, a, s.decision.jsonName());
        try b.appendSlice(a, ", \"unsupported\": ");
        try appendBool(&b, a, s.unsupported);
        try b.appendSlice(a, " }");
        if (i + 1 < signals.len) try b.append(a, ',');
        try b.append(a, '\n');
    }
    try b.appendSlice(a, "  ]\n}\n");
    return try b.toOwnedSlice(a);
}

fn emitManualReview(a: std.mem.Allocator, signals: []const Signal) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\n  \"format\": \"boris-wordpress-theme-manual-review\",\n  \"schema_version\": 1,\n  \"policy\": { \"execute_php\": false, \"preserve_every_dynamic_finding\": true },\n  \"items\": [\n");
    var first = true;
    for (signals) |s| {
        if (!s.unsupported and !std.mem.eql(u8, s.category, "template_relationship")) continue;
        if (!first) try b.appendSlice(a, ",\n");
        first = false;
        try b.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&b, a, s.source_path);
        try b.appendSlice(a, ", \"line\": ");
        try appendUsize(&b, a, s.line);
        try b.appendSlice(a, ", \"behavior\": ");
        try appendJson(&b, a, s.name);
        try b.appendSlice(a, ", \"evidence\": ");
        try appendJson(&b, a, s.evidence);
        try b.appendSlice(a, ", \"decision\": ");
        try appendJson(&b, a, s.decision.jsonName());
        try b.appendSlice(a, ", \"review_reason\": ");
        try appendJson(&b, a, s.proposed);
        try b.appendSlice(a, " }");
    }
    try b.appendSlice(a, "\n  ]\n}\n");
    return try b.toOwnedSlice(a);
}

fn slotForSignal(signal: Signal) ?[]const u8 {
    if (std.mem.eql(u8, signal.name, "the_title") or std.mem.eql(u8, signal.name, "wp_title")) return "title";
    if (std.mem.eql(u8, signal.name, "the_content")) return "content";
    if (std.mem.startsWith(u8, signal.name, "wp_nav_menu")) return "nav";
    if (std.mem.eql(u8, signal.name, "wp_list_pages")) return "children";
    if (std.mem.eql(u8, signal.name, "get_footer")) return "footer";
    return null;
}

fn appendSlotCandidateJson(b: *std.ArrayList(u8), a: std.mem.Allocator, signal: Signal, slot: []const u8) !void {
    try b.appendSlice(a, "    { \"slot\": ");
    try appendJson(b, a, slot);
    try b.appendSlice(a, ", \"source_path\": ");
    try appendJson(b, a, signal.source_path);
    try b.appendSlice(a, ", \"line\": ");
    try appendUsize(b, a, signal.line);
    try b.appendSlice(a, ", \"evidence\": ");
    try appendJson(b, a, signal.evidence);
    try b.appendSlice(a, ", \"decision\": \"review\", \"proposed_layout_marker\": \"{{");
    try b.appendSlice(a, slot);
    try b.appendSlice(a, "}}\" }");
}

fn emitSlots(a: std.mem.Allocator, signals: []const Signal) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\n  \"format\": \"boris-wordpress-theme-static-prototype\",\n  \"schema_version\": 1,\n  \"evidence_policy\": \"Candidates are emitted only from detected source lines; none is an automatic conversion or a claim about absent source evidence.\",\n  \"candidates\": [\n");
    var first = true;
    for (signals) |signal| {
        const slot = slotForSignal(signal) orelse continue;
        if (!first) try b.appendSlice(a, ",\n");
        first = false;
        try appendSlotCandidateJson(&b, a, signal, slot);
    }
    try b.appendSlice(a, "\n  ]\n}\n");
    return try b.toOwnedSlice(a);
}

fn emitPrototype(a: std.mem.Allocator) ![]u8 {
    // This validates only the Boris layout contract. It does not assert that a
    // source stylesheet or optional WordPress shell has been materialised.
    return try a.dupe(u8, "<!doctype html>\n<html>\n<head>\n  <meta charset=\"utf-8\">\n  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n  <title>{{title}}</title>\n</head>\n<body>\n  <main>\n    {{content}}\n  </main>\n</body>\n</html>\n");
}

fn emitReport(a: std.mem.Allocator, root: []const u8, files: []const FileRec, signals: []const Signal) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "{\n  \"format\": \"" ++ format_id ++ "\",\n  \"schema_version\": 1,\n  \"tool_version\": \"");
    try b.appendSlice(a, tool_version);
    try b.appendSlice(a, "\",\n  \"source_root\": ");
    try appendJson(&b, a, root);
    try b.appendSlice(a, ",\n  \"counts\": { \"files\": ");
    try appendUsize(&b, a, files.len);
    try b.appendSlice(a, ", \"php_files\": ");
    var php: usize = 0;
    for (files) |f| {
        if (classifyTemplate(f.path) == .generic_php or std.mem.endsWith(u8, f.path, ".php")) php += 1;
    }
    try appendUsize(&b, a, php);
    try b.appendSlice(a, ", \"assets\": ");
    var assets: usize = 0;
    for (files) |f| {
        if (classifyTemplate(f.path) == .asset or classifyTemplate(f.path) == .stylesheet) assets += 1;
    }
    try appendUsize(&b, a, assets);
    try b.appendSlice(a, ", \"block_theme_configs\": ");
    try appendUsize(&b, a, countFiles(files, .theme_json));
    try b.appendSlice(a, ", \"block_templates\": ");
    try appendUsize(&b, a, countFiles(files, .block_template));
    try b.appendSlice(a, ", \"dynamic_findings\": ");
    try appendUsize(&b, a, signals.len);
    try b.appendSlice(a, ", \"menus\": ");
    try appendUsize(&b, a, countSignals(signals, "menu"));
    try b.appendSlice(a, ", \"widgets\": ");
    try appendUsize(&b, a, countSignals(signals, "widget"));
    try b.appendSlice(a, ", \"template_relationships\": ");
    try appendUsize(&b, a, countSignals(signals, "template_relationship"));
    try b.appendSlice(a, ", \"manual_review\": ");
    var review: usize = 0;
    for (signals) |s| {
        if (s.unsupported or std.mem.eql(u8, s.category, "template_relationship")) review += 1;
    }
    try appendUsize(&b, a, review);
    try b.appendSlice(a, " },\n  \"decisions\": { \"preserve\": ");
    var n: usize = 0;
    for (files) |f| {
        if (fileDecision(f.path) == .preserve) n += 1;
    }
    for (signals) |s| {
        if (s.decision == .preserve) n += 1;
    }
    try appendUsize(&b, a, n);
    try b.appendSlice(a, ", \"adapt\": ");
    n = 0;
    for (files) |f| {
        if (fileDecision(f.path) == .adapt) n += 1;
    }
    for (signals) |s| {
        if (s.decision == .adapt) n += 1;
    }
    try appendUsize(&b, a, n);
    try b.appendSlice(a, ", \"review\": ");
    n = 0;
    for (files) |f| {
        if (fileDecision(f.path) == .review) n += 1;
    }
    for (signals) |s| {
        if (s.decision == .review) n += 1;
    }
    try appendUsize(&b, a, n);
    try b.appendSlice(a, ", \"drop\": ");
    n = 0;
    for (files) |f| {
        if (fileDecision(f.path) == .drop) n += 1;
    }
    for (signals) |s| {
        if (s.decision == .drop) n += 1;
    }
    try appendUsize(&b, a, n);
    try b.appendSlice(a, " },\n  \"evidence_boundary\": [\"Source files are inventoried and line-scanned only\", \"PHP is never executed\", \"WordPress core/plugin behavior is not inferred\", \"Block theme theme.json and templates/*.html are static inventory evidence only\", \"Block JSON is not parsed and blocks are not rendered\", \"Remote assets and network behavior are outside this run\", \"This fixture is representative, not an authentic Kubrick distribution\"]\n}\n");
    return try b.toOwnedSlice(a);
}

fn emitReportMd(a: std.mem.Allocator, files: []const FileRec, signals: []const Signal) ![]u8 {
    var b: std.ArrayList(u8) = .empty;
    try b.appendSlice(a, "# WordPress theme archaeology report\n\n" ++
        "This is a deterministic, read-only scan of a small WordPress-theme-shaped fixture. " ++
        "Fixtures are representative only and this tool never executes PHP or JavaScript.\n\n" ++
        "## Evidence boundary\n\n" ++
        "The lab sees filenames, bytes, hashes, and source-line text. It does not run PHP or JavaScript, load WordPress, resolve hooks, inspect plugins/database state, render a browser, fetch remote assets, parse block JSON, render blocks, or claim universal WordPress compatibility. Every detected dynamic behavior is retained in `manual_review.json`.\n\n" ++
        "## Inventory\n\n| Path | Classification | Bytes | SHA-256 |\n|---|---|---:|---|\n");
    for (files) |f| {
        try b.appendSlice(a, "| `");
        try b.appendSlice(a, f.path);
        try b.appendSlice(a, "` | `");
        try b.appendSlice(a, classifyTemplate(f.path).jsonName());
        try b.appendSlice(a, "` | ");
        try appendUsize(&b, a, f.bytes);
        try b.appendSlice(a, " | `");
        try b.appendSlice(a, f.sha256);
        try b.appendSlice(a, "` |\n");
    }
    try b.appendSlice(a, "\n## Block theme / FSE static evidence\n\n`theme.json` and direct `templates/*.html` files are recorded only as static bytes and hashes. The lab does not parse `theme.json`, interpret block markup, render block templates, or claim full WordPress parity.\n\n| Kind | Path | Bytes | SHA-256 | Decision |\n|---|---|---:|---|---|\n");
    var block_found = false;
    for (files) |file| {
        const kind = classifyTemplate(file.path);
        if (kind != .theme_json and kind != .block_template) continue;
        block_found = true;
        try b.appendSlice(a, "| `");
        try b.appendSlice(a, kind.jsonName());
        try b.appendSlice(a, "` | `");
        try b.appendSlice(a, file.path);
        try b.appendSlice(a, "` | ");
        try appendUsize(&b, a, file.bytes);
        try b.appendSlice(a, " | `");
        try b.appendSlice(a, file.sha256);
        try b.appendSlice(a, "` | preserve (inventory only) |\n");
    }
    if (!block_found) try b.appendSlice(a, "| — | — | — | — | No block-theme static evidence found |\n");
    try b.appendSlice(a, "\n## Prototype contract and slot evidence\n\nThe prototype is a minimal valid Boris layout: it contains one `{{title}}` and one `{{content}}`, with no `asset-url` helper because this mode inventories source files and does not materialise assets. It is a compiler-contract smoke input, not a converted WordPress theme.\n\n`slot_mapping.json` records only candidates with exact line evidence below. A missing candidate is not inferred from filenames, template roles, or WordPress conventions. Every candidate remains `review`; this lab does not select a layout slot or convert runtime behavior.\n\n| Boris marker candidate | Source line | Evidence | Decision |\n|---|---|---|---|\n");
    var candidate_found = false;
    for (signals) |signal| {
        const slot = slotForSignal(signal) orelse continue;
        candidate_found = true;
        try b.appendSlice(a, "| `{{");
        try b.appendSlice(a, slot);
        try b.appendSlice(a, "}}` | `");
        try b.appendSlice(a, signal.source_path);
        try b.appendSlice(a, ":");
        try appendUsize(&b, a, signal.line);
        try b.appendSlice(a, "` | `");
        for (signal.evidence) |c| {
            if (c != '`' and c != '\n' and c != '\r' and c != '|') try b.append(a, c);
        }
        try b.appendSlice(a, "` | review |\n");
    }
    if (!candidate_found) try b.appendSlice(a, "| — | — | No direct slot evidence detected | review |\n");
    try b.appendSlice(a, "\n## Dynamic findings\n\n");
    for (signals) |s| {
        try b.appendSlice(a, "- `");
        try b.appendSlice(a, s.source_path);
        try b.appendSlice(a, ":");
        try appendUsize(&b, a, s.line);
        try b.appendSlice(a, "` **");
        try b.appendSlice(a, s.name);
        try b.appendSlice(a, "** — `");
        try b.appendSlice(a, s.decision.jsonName());
        try b.appendSlice(a, "`; evidence: `");
        for (s.evidence) |c| {
            if (c != '`' and c != '\n' and c != '\r') try b.append(a, c);
        }
        try b.appendSlice(a, "`\n");
    }
    try b.appendSlice(a, "\n## Artifacts\n\n- `inventory.json` — sorted file, static FSE evidence, and signal inventory\n- `slot_mapping.json` — line-evidenced Boris slot candidates requiring review\n- `manual_review.json` — all unsupported/dynamic evidence with source lines\n- `prototype/main.html` — static no-runtime layout-contract smoke input\n- `report.json` — counts and policy\n\nDecisions use `preserve` for static bytes/provenance, `adapt` for a closed slot mapping, `review` for ambiguous or runtime-backed behavior, and `drop` for refused runtime-only behavior.\n");
    return try b.toOwnedSlice(a);
}

pub fn refuseOutputInsideSource(source: []const u8, out: []const u8) !void {
    if (std.mem.eql(u8, source, out)) return error.OutputInsideSource;
    if (source.len < out.len and std.mem.startsWith(u8, out, source) and (out[source.len] == '/' or out[source.len] == '\\')) return error.OutputInsideSource;
    return;
}

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{}) catch return error.SourceNotFound;
    defer root.close(io);
    var files: std.ArrayList(FileRec) = .empty;
    try walkTree(io, a, root, "", &files);
    std.mem.sort(FileRec, files.items, {}, fileLess);
    var signals: std.ArrayList(Signal) = .empty;
    for (files.items) |f| {
        if (!isText(f.path)) continue;
        const data = readFileAlloc(io, root, f.path, a) catch continue;
        if (std.mem.endsWith(u8, f.path, ".php")) try scanPhp(a, f.path, data, &signals);
        if (std.ascii.eqlIgnoreCase(fileExtension(f.path), ".css") and std.ascii.eqlIgnoreCase(std.fs.path.basename(f.path), "style.css")) try scanStyle(a, f.path, data, &signals);
    }
    std.mem.sort(Signal, signals.items, {}, signalLess);
    var output_publication = try publication.Publication.begin(io, gpa, opts.out_dir, &.{opts.root_dir}, format_id);
    defer {
        output_publication.abandon(io, gpa);
        output_publication.deinit(gpa);
    }
    var out = try Io.Dir.cwd().openDir(io, output_publication.stage_path, .{});
    var out_open = true;
    errdefer if (out_open) out.close(io);
    try writeBytes(io, out, "inventory.json", try emitInventory(a, opts.root_dir, files.items, signals.items));
    try writeBytes(io, out, "manual_review.json", try emitManualReview(a, signals.items));
    try writeBytes(io, out, "slot_mapping.json", try emitSlots(a, signals.items));
    try writeBytes(io, out, "prototype/main.html", try emitPrototype(a));
    try writeBytes(io, out, "report.json", try emitReport(a, opts.root_dir, files.items, signals.items));
    try writeBytes(io, out, "REPORT.md", try emitReportMd(a, files.items, signals.items));
    if (!opts.quiet) std.debug.print("wordpress-theme-lab: wrote {s} ({d} files, {d} findings)\n", .{ opts.out_dir, files.items.len, signals.items.len });
    out.close(io);
    out_open = false;
    try output_publication.commit(io, gpa);
}

test "classifyTemplate: classic WordPress hierarchy" {
    try std.testing.expect(classifyTemplate("index.php") == .index);
    try std.testing.expect(classifyTemplate("single.php") == .single);
    try std.testing.expect(classifyTemplate("page.php") == .page);
    try std.testing.expect(classifyTemplate("header.php") == .header);
    try std.testing.expect(classifyTemplate("footer.php") == .footer);
    try std.testing.expect(classifyTemplate("sidebar.php") == .sidebar);
    try std.testing.expect(classifyTemplate("functions.php") == .functions);
    try std.testing.expect(classifyTemplate("searchform.php") == .search_form);
    try std.testing.expect(classifyTemplate("style.css") == .stylesheet);
    try std.testing.expect(classifyTemplate("theme.json") == .theme_json);
    try std.testing.expect(classifyTemplate("templates/index.html") == .block_template);
    try std.testing.expect(classifyTemplate("templates/parts/header.html") == .other);
    try std.testing.expect(classifyTemplate("images/logo.svg") == .asset);
    try std.testing.expect(classifyTemplate("custom-template.php") == .generic_php);
}

test "fixture mini-wordpress-block-theme: inventories static FSE evidence only" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const root = "fixtures/mini-wordpress-block-theme";
    const out = "fixtures/.tmp-wp-block-theme";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};
    try run(io, a, .{ .root_dir = root, .out_dir = out, .quiet = true });
    var report = try Io.Dir.cwd().openDir(io, out, .{});
    defer report.close(io);
    const inventory = try readFileAlloc(io, report, "inventory.json", a);
    defer a.free(inventory);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "\"theme_json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "templates/index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, inventory, "\"scope\": \"static inventory only\"") != null);
    const summary = try readFileAlloc(io, report, "report.json", a);
    defer a.free(summary);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"block_theme_configs\": 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, summary, "\"block_templates\": 2") != null);
    const slots = try readFileAlloc(io, report, "slot_mapping.json", a);
    defer a.free(slots);
    try std.testing.expect(std.mem.indexOf(u8, slots, "\"slot\"") == null);
    const markdown = try readFileAlloc(io, report, "REPORT.md", a);
    defer a.free(markdown);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "Block theme / FSE static evidence") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "does not parse `theme.json`, interpret block markup, render block templates") != null);
}

test "fixture mini-wordpress-kubrick: deterministic inventory and review preservation" {
    const io = std.testing.io;
    const a = std.testing.allocator;
    const root = "fixtures/mini-wordpress-kubrick";
    const out_a = "fixtures/.tmp-wp-theme-a";
    const out_b = "fixtures/.tmp-wp-theme-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_a) catch {};
    defer Io.Dir.cwd().deleteTree(io, out_b) catch {};
    try run(io, a, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, a, .{ .root_dir = root, .out_dir = out_b, .quiet = true });
    var da = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer da.close(io);
    var db = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer db.close(io);
    const names = [_][]const u8{ "inventory.json", "manual_review.json", "slot_mapping.json", "report.json", "REPORT.md", "prototype/main.html" };
    for (names) |name| {
        const x = try readFileAlloc(io, da, name, a);
        defer a.free(x);
        const y = try readFileAlloc(io, db, name, a);
        defer a.free(y);
        try std.testing.expectEqualStrings(x, y);
    }
    const inv = try readFileAlloc(io, da, "inventory.json", a);
    defer a.free(inv);
    try std.testing.expect(std.mem.indexOf(u8, inv, "register_nav_menus") != null);
    try std.testing.expect(std.mem.indexOf(u8, inv, "dynamic_sidebar") != null);
    try std.testing.expect(std.mem.indexOf(u8, inv, "template_relationship") != null);
    const review = try readFileAlloc(io, da, "manual_review.json", a);
    defer a.free(review);
    try std.testing.expect(std.mem.indexOf(u8, review, "wp_footer") != null);
    try std.testing.expect(std.mem.indexOf(u8, review, "wp_enqueue_script") != null);
    const prototype = try readFileAlloc(io, da, "prototype/main.html", a);
    defer a.free(prototype);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(prototype, "{{title}}"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(prototype, "{{content}}"));
    try std.testing.expect(std.mem.indexOf(u8, prototype, "{{asset-url") == null);
    const slots = try readFileAlloc(io, da, "slot_mapping.json", a);
    defer a.free(slots);
    try std.testing.expect(std.mem.indexOf(u8, slots, "\"candidates\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, slots, "\"decision\": \"review\"") != null);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, pos, needle)) |at| {
        count += 1;
        pos = at + needle.len;
    }
    return count;
}

test "wordpress-theme: emitted prototype compiles with product Boris" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer {
        tmp.dir.close(io);
        tmp.parent_dir.deleteTree(io, &tmp.sub_path) catch |err| {
            std.debug.panic("failed to clean WordPress theme compile test directory: {s}", .{@errorName(err)});
        };
        tmp.parent_dir.close(io);
    }

    const test_root = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/wordpress-theme-prototype", .{tmp.sub_path});
    defer gpa.free(test_root);
    const report_out = try std.fmt.allocPrint(gpa, "{s}/report", .{test_root});
    defer gpa.free(report_out);
    const content_out = try std.fmt.allocPrint(gpa, "{s}/content", .{test_root});
    defer gpa.free(content_out);
    const theme_out = try std.fmt.allocPrint(gpa, "{s}/theme", .{test_root});
    defer gpa.free(theme_out);
    const theme_layouts = try std.fmt.allocPrint(gpa, "{s}/layouts", .{theme_out});
    defer gpa.free(theme_layouts);
    const html_out = try std.fmt.allocPrint(gpa, "{s}/html", .{test_root});
    defer gpa.free(html_out);

    try run(io, gpa, .{
        .root_dir = "fixtures/mini-wordpress-kubrick",
        .out_dir = report_out,
        .quiet = true,
    });
    var report = try Io.Dir.cwd().openDir(io, report_out, .{});
    defer report.close(io);
    const prototype = try readFileAlloc(io, report, "prototype/main.html", gpa);
    defer gpa.free(prototype);

    try Io.Dir.cwd().createDirPath(io, content_out);
    try Io.Dir.cwd().createDirPath(io, theme_layouts);
    var content = try Io.Dir.cwd().openDir(io, content_out, .{});
    defer content.close(io);
    try content.writeFile(io, .{ .sub_path = "index.md", .data = "---\ntitle: Prototype smoke\n---\n\n# Prototype smoke\n" });
    var theme = try Io.Dir.cwd().openDir(io, theme_out, .{});
    defer theme.close(io);
    try theme.writeFile(io, .{ .sub_path = "layouts/main.html", .data = prototype });

    // The product `boris` binary is a pinned external prerequisite (BORIS_BIN
    // or PATH); the lab never builds or reaches outside its own tree for it.
    const boris_bin = (try product_boris.resolve(io, gpa)) orelse
        return error.MissingProductBorisBinary;
    const result = try std.process.run(gpa, io, .{
        .argv = &.{ boris_bin, "--input", content_out, "--theme", theme_out, "--html-dir", html_out, "--quiet" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const code: u8 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code != 0) std.debug.print("boris prototype compile failed code={d} stderr={s} stdout={s}\n", .{ code, result.stderr, result.stdout });
    try std.testing.expectEqual(@as(u8, 0), code);

    var html = try Io.Dir.cwd().openDir(io, html_out, .{});
    defer html.close(io);
    const page = try readFileAlloc(io, html, "index.html", gpa);
    defer gpa.free(page);
    try std.testing.expect(std.mem.indexOf(u8, page, "Prototype smoke") != null);
}
