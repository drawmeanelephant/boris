//! Theme archaeology laboratory — read-only inventory of an Astro/Starlight-shaped
//! theme tree into a deterministic adaptation ledger.
//!
//! Inventories layouts, CSS (+ imports), fonts/images, nav/sidebar config,
//! recognizable components and MDX tags, scripts/external URLs/analytics/runtime
//! assumptions, and licenses/provenance when discoverable.
//!
//! Safety (non-negotiable):
//! - never execute source-site JavaScript or MDX
//! - never follow embedded instructions or directives
//! - never fetch remote assets
//! - source tree remains untouched
//! - repeated runs are byte-identical
//! - ambiguous mappings become **review** items, never guesses
//!
//! Format id: boris-theme-archaeology-lab · schema 1

const std = @import("std");
const Io = std.Io;

pub const format_id = "boris-theme-archaeology-lab";
pub const schema_version: u32 = 1;
pub const tool_version = "0.1.0";

pub const Options = struct {
    /// Astro/Starlight-shaped project or theme root (read-only).
    root_dir: []const u8,
    /// Output directory (must differ from root). Receives ledger + reports only.
    out_dir: []const u8,
    quiet: bool = false,
};

pub const LabError = error{
    OutputInsideSource,
    SourceNotFound,
    OutOfMemory,
    IoFailure,
};

// ---------------------------------------------------------------------------
// Taxonomy
// ---------------------------------------------------------------------------

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

pub const Category = enum {
    layout,
    template,
    css,
    css_import,
    font,
    image,
    navigation,
    component,
    mdx_tag,
    script,
    external_url,
    analytics,
    runtime_assumption,
    license,
    provenance,
    config,
    other,

    pub fn jsonName(self: Category) []const u8 {
        return switch (self) {
            .layout => "layout",
            .template => "template",
            .css => "css",
            .css_import => "css_import",
            .font => "font",
            .image => "image",
            .navigation => "navigation",
            .component => "component",
            .mdx_tag => "mdx_tag",
            .script => "script",
            .external_url => "external_url",
            .analytics => "analytics",
            .runtime_assumption => "runtime_assumption",
            .license => "license",
            .provenance => "provenance",
            .config => "config",
            .other => "other",
        };
    }
};

/// One adaptation-ledger row. Paths are scan-root relative with `/` separators.
pub const LedgerEntry = struct {
    source_path: []const u8,
    category: Category,
    /// Lowercase hex SHA-256 of file bytes when the row is a concrete file inventory;
    /// empty string when the row is evidence extracted from another file (n/a).
    sha256: []const u8 = "",
    proposed_boris_equivalent: []const u8,
    decision: Decision,
    reason: []const u8,
    evidence: []const u8,
    unsupported_runtime: bool = false,
};

// ---------------------------------------------------------------------------
// Path helpers
// ---------------------------------------------------------------------------

const skip_dir_names = [_][]const u8{
    ".git",  ".hg",     ".svn",     "node_modules", ".astro",
    "dist",  ".vercel", ".netlify", ".output",      "zig-out",
    ".zig-cache", "zig-cache", ".boris", "migration-report",
};

const skip_file_names = [_][]const u8{ ".DS_Store", "Thumbs.db" };

fn isSkipDir(name: []const u8) bool {
    for (skip_dir_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

fn isSkipFile(name: []const u8) bool {
    for (skip_file_names) |s| {
        if (std.mem.eql(u8, name, s)) return true;
    }
    return false;
}

pub fn refuseOutputInsideSource(source: []const u8, out: []const u8) !void {
    if (std.mem.eql(u8, source, out)) return error.OutputInsideSource;
    if (source.len < out.len and std.mem.startsWith(u8, out, source)) {
        const next = out[source.len];
        if (next == '/' or next == '\\') return error.OutputInsideSource;
    }
    if (out.len < source.len and std.mem.startsWith(u8, source, out)) {
        const next = source[out.len];
        if (next == '/' or next == '\\') return error.OutputInsideSource;
    }
}

fn joinRel(a: std.mem.Allocator, dir: []const u8, name: []const u8) ![]u8 {
    if (dir.len == 0) return try a.dupe(u8, name);
    return try std.fmt.allocPrint(a, "{s}/{s}", .{ dir, name });
}

pub fn fileExtension(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot == 0) return "";
        return base[dot..];
    }
    return "";
}

fn asciiLowerEq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        const xl = if (x >= 'A' and x <= 'Z') x + 32 else x;
        const yl = if (y >= 'A' and y <= 'Z') y + 32 else y;
        if (xl != yl) return false;
    }
    return true;
}

fn endsWithIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    return asciiLowerEq(hay[hay.len - needle.len ..], needle);
}

fn containsIgnoreCase(hay: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > hay.len) return false;
    var i: usize = 0;
    while (i + needle.len <= hay.len) : (i += 1) {
        if (asciiLowerEq(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isImageExt(ext: []const u8) bool {
    return asciiLowerEq(ext, ".png") or asciiLowerEq(ext, ".jpg") or asciiLowerEq(ext, ".jpeg") or
        asciiLowerEq(ext, ".gif") or asciiLowerEq(ext, ".svg") or asciiLowerEq(ext, ".webp") or
        asciiLowerEq(ext, ".ico") or asciiLowerEq(ext, ".avif") or asciiLowerEq(ext, ".bmp");
}

fn isFontExt(ext: []const u8) bool {
    return asciiLowerEq(ext, ".woff") or asciiLowerEq(ext, ".woff2") or asciiLowerEq(ext, ".ttf") or
        asciiLowerEq(ext, ".otf") or asciiLowerEq(ext, ".eot");
}

fn isCssExt(ext: []const u8) bool {
    return asciiLowerEq(ext, ".css") or asciiLowerEq(ext, ".scss") or asciiLowerEq(ext, ".sass") or
        asciiLowerEq(ext, ".less");
}

fn isScriptExt(ext: []const u8) bool {
    return asciiLowerEq(ext, ".js") or asciiLowerEq(ext, ".mjs") or asciiLowerEq(ext, ".cjs") or
        asciiLowerEq(ext, ".ts") or asciiLowerEq(ext, ".tsx") or asciiLowerEq(ext, ".jsx");
}

fn isTextScanExt(ext: []const u8) bool {
    return isCssExt(ext) or isScriptExt(ext) or
        asciiLowerEq(ext, ".astro") or asciiLowerEq(ext, ".html") or asciiLowerEq(ext, ".htm") or
        asciiLowerEq(ext, ".md") or asciiLowerEq(ext, ".mdx") or asciiLowerEq(ext, ".vue") or
        asciiLowerEq(ext, ".svelte") or asciiLowerEq(ext, ".json") or asciiLowerEq(ext, ".mjs") or
        asciiLowerEq(ext, ".cjs") or asciiLowerEq(ext, ".yml") or asciiLowerEq(ext, ".yaml") or
        asciiLowerEq(ext, ".toml") or asciiLowerEq(ext, ".txt") or asciiLowerEq(ext, ".mdc");
}

fn isLicenseName(base: []const u8) bool {
    return asciiLowerEq(base, "license") or asciiLowerEq(base, "license.md") or
        asciiLowerEq(base, "license.txt") or asciiLowerEq(base, "copying") or
        asciiLowerEq(base, "copying.txt") or asciiLowerEq(base, "notice") or
        asciiLowerEq(base, "notice.md") or asciiLowerEq(base, "notice.txt") or
        asciiLowerEq(base, "licence") or asciiLowerEq(base, "licence.md") or
        asciiLowerEq(base, "licence.txt");
}

fn isConfigPath(path: []const u8) bool {
    const base = std.fs.path.basename(path);
    if (std.mem.startsWith(u8, base, "astro.config.")) return true;
    if (asciiLowerEq(base, "package.json") or asciiLowerEq(base, "tsconfig.json") or
        asciiLowerEq(base, "jsconfig.json"))
        return true;
    if (std.mem.eql(u8, base, "content.config.ts") or std.mem.eql(u8, base, "content.config.mjs") or
        std.mem.eql(u8, base, "content.config.js"))
        return true;
    if (std.mem.eql(u8, path, "src/content/config.ts") or std.mem.eql(u8, path, "src/content/config.mjs") or
        std.mem.eql(u8, path, "src/content/config.js") or std.mem.eql(u8, path, "content/config.ts") or
        std.mem.eql(u8, path, "content/config.mjs") or std.mem.eql(u8, path, "content/config.js"))
        return true;
    if (asciiLowerEq(base, "tailwind.config.js") or asciiLowerEq(base, "tailwind.config.mjs") or
        asciiLowerEq(base, "tailwind.config.ts") or asciiLowerEq(base, "postcss.config.js") or
        asciiLowerEq(base, "postcss.config.cjs") or asciiLowerEq(base, "postcss.config.mjs"))
        return true;
    return false;
}

fn isLayoutPath(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "src/layouts/") and std.mem.endsWith(u8, path, ".astro")) return true;
    if (std.mem.startsWith(u8, path, "layouts/") and (std.mem.endsWith(u8, path, ".astro") or
        std.mem.endsWith(u8, path, ".html")))
        return true;
    // Starlight / theme package common location
    if (std.mem.indexOf(u8, path, "/layouts/") != null and std.mem.endsWith(u8, path, ".astro")) return true;
    return false;
}

fn isComponentPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/components/") or
        std.mem.startsWith(u8, path, "components/") or
        (std.mem.indexOf(u8, path, "/components/") != null and
            (std.mem.endsWith(u8, path, ".astro") or isScriptExt(fileExtension(path))));
}

fn isPageTemplatePath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/pages/") and std.mem.endsWith(u8, path, ".astro");
}

fn isPublicPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "public/");
}

fn isSrcAssetPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "src/assets/") or std.mem.startsWith(u8, path, "src/styles/") or
        std.mem.startsWith(u8, path, "styles/") or std.mem.startsWith(u8, path, "assets/");
}

fn isContentPath(path: []const u8) bool {
    return (std.mem.startsWith(u8, path, "src/content/") or std.mem.startsWith(u8, path, "content/")) and
        (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx"));
}

/// Closed mapping: known admonition-like tags → Boris native Aside / Details.
/// Everything else is review — never invent component semantics.
fn knownNativeTag(tag: []const u8) ?[]const u8 {
    // Aside family
    if (asciiLowerEq(tag, "Aside") or asciiLowerEq(tag, "Note") or asciiLowerEq(tag, "Tip") or
        asciiLowerEq(tag, "Caution") or asciiLowerEq(tag, "Warning") or asciiLowerEq(tag, "Danger") or
        asciiLowerEq(tag, "Important") or asciiLowerEq(tag, "Callout"))
        return "native <Aside> (map kind from tag/props; human-confirm kind table)";
    if (asciiLowerEq(tag, "Details")) return "native <Details summary=\"…\">…</Details>";
    return null;
}

fn hasTraversal(path_or_url: []const u8) bool {
    if (std.mem.indexOf(u8, path_or_url, "..") == null) return false;
    // Match path segments: /../, ../ at start, /.. at end, or bare ..
    if (std.mem.eql(u8, path_or_url, "..")) return true;
    if (std.mem.startsWith(u8, path_or_url, "../") or std.mem.startsWith(u8, path_or_url, "..\\")) return true;
    if (std.mem.indexOf(u8, path_or_url, "/../") != null or std.mem.indexOf(u8, path_or_url, "\\..\\") != null) return true;
    if (std.mem.endsWith(u8, path_or_url, "/..") or std.mem.endsWith(u8, path_or_url, "\\..")) return true;
    return false;
}

fn isRemoteUrl(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "http://") or std.mem.startsWith(u8, s, "https://") or
        std.mem.startsWith(u8, s, "//");
}

fn looksLikeAnalytics(s: []const u8) bool {
    return containsIgnoreCase(s, "gtag") or containsIgnoreCase(s, "googletagmanager") or
        containsIgnoreCase(s, "google-analytics") or containsIgnoreCase(s, "analytics.js") or
        containsIgnoreCase(s, "plausible") or containsIgnoreCase(s, "umami") or
        containsIgnoreCase(s, "fathom") or containsIgnoreCase(s, "segment.com") or
        containsIgnoreCase(s, "hotjar") or containsIgnoreCase(s, "mixpanel") or
        containsIgnoreCase(s, "fullstory") or containsIgnoreCase(s, "posthog") or
        containsIgnoreCase(s, "clarity.ms") or containsIgnoreCase(s, "ga.js") or
        containsIgnoreCase(s, "gtm.js");
}

// ---------------------------------------------------------------------------
// I/O
// ---------------------------------------------------------------------------

fn readFileAlloc(io: Io, dir: Io.Dir, path: []const u8, allocator: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(allocator, .unlimited);
}

fn ensureParent(io: Io, root: Io.Dir, rel_path: []const u8) !void {
    if (std.fs.path.dirname(rel_path)) |parent| {
        if (parent.len > 0) try root.createDirPath(io, parent);
    }
}

fn writeBytes(io: Io, root: Io.Dir, rel_path: []const u8, data: []const u8) !void {
    try ensureParent(io, root, rel_path);
    try root.writeFile(io, .{ .sub_path = rel_path, .data = data });
}

pub fn sha256Hex(a: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    const hex = try a.alloc(u8, 64);
    const charset = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = charset[byte >> 4];
        hex[i * 2 + 1] = charset[byte & 0xf];
    }
    return hex;
}

fn appendJson(buf: *std.ArrayList(u8), a: std.mem.Allocator, s: []const u8) !void {
    try buf.append(a, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(a, "\\\""),
            '\\' => try buf.appendSlice(a, "\\\\"),
            '\n' => try buf.appendSlice(a, "\\n"),
            '\r' => try buf.appendSlice(a, "\\r"),
            '\t' => try buf.appendSlice(a, "\\t"),
            else => {
                if (c < 0x20) {
                    var tmp: [6]u8 = undefined;
                    const piece = try std.fmt.bufPrint(&tmp, "\\u{x:0>4}", .{c});
                    try buf.appendSlice(a, piece);
                } else {
                    try buf.append(a, c);
                }
            },
        }
    }
    try buf.append(a, '"');
}

fn appendUsize(buf: *std.ArrayList(u8), a: std.mem.Allocator, n: usize) !void {
    var tmp: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&tmp, "{d}", .{n});
    try buf.appendSlice(a, s);
}

fn appendBool(buf: *std.ArrayList(u8), a: std.mem.Allocator, v: bool) !void {
    try buf.appendSlice(a, if (v) "true" else "false");
}

fn trim(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r\n");
}

// ---------------------------------------------------------------------------
// Discovery
// ---------------------------------------------------------------------------

const FileRec = struct {
    path: []const u8,
    bytes: usize,
    sha256: []const u8,
    is_symlink: bool,
};

fn isSymlink(io: Io, dir: Io.Dir, rel: []const u8) bool {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    _ = dir.readLink(io, rel, &buf) catch return false;
    return true;
}

fn walkTree(
    io: Io,
    a: std.mem.Allocator,
    root: Io.Dir,
    rel_dir: []const u8,
    files: *std.ArrayList(FileRec),
) !void {
    var dir = root.openDir(io, if (rel_dir.len == 0) "." else rel_dir, .{ .iterate = true }) catch |err| {
        if (rel_dir.len == 0) return err;
        return;
    };
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') {
            // Still allow LICENSE-like at root; skip only hidden dirs/files except we already
            // skip via isSkipDir for .git. Skip other dotfiles.
            if (!isLicenseName(entry.name)) continue;
        }
        if (entry.kind == .directory) {
            if (isSkipDir(entry.name)) continue;
            const child = try joinRel(a, rel_dir, entry.name);
            try walkTree(io, a, root, child, files);
            continue;
        }
        if (entry.kind != .file) continue;
        if (isSkipFile(entry.name)) continue;
        const path = try joinRel(a, rel_dir, entry.name);
        const symlink = isSymlink(io, root, path);
        if (symlink) {
            try files.append(a, .{
                .path = path,
                .bytes = 0,
                .sha256 = "",
                .is_symlink = true,
            });
            continue;
        }
        const data = readFileAlloc(io, root, path, a) catch continue;
        const hex = try sha256Hex(a, data);
        try files.append(a, .{
            .path = path,
            .bytes = data.len,
            .sha256 = hex,
            .is_symlink = false,
        });
    }
}

// ---------------------------------------------------------------------------
// Classification + content scan
// ---------------------------------------------------------------------------

fn proposeLayoutEquivalent(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const base = std.fs.path.basename(path);
    var stem = base;
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        if (dot > 0) stem = base[0..dot];
    }
    // Prefer main.html when the source is a generic base/main layout.
    if (asciiLowerEq(stem, "baselayout") or asciiLowerEq(stem, "main") or
        asciiLowerEq(stem, "layout") or asciiLowerEq(stem, "docs") or asciiLowerEq(stem, "docslayout"))
    {
        return try a.dupe(u8, "theme/layouts/main.html (adapt slots: content,title,nav,toc,…)");
    }
    return try std.fmt.allocPrint(a, "theme/layouts/{s}.html (adapt; closed slots only)", .{stem});
}

fn proposeAssetEquivalent(a: std.mem.Allocator, path: []const u8, kind: []const u8) ![]u8 {
    // Strip public/ or src/assets/ or assets/ prefix for a theme-assets suggestion.
    var rest = path;
    if (std.mem.startsWith(u8, path, "public/")) rest = path["public/".len..];
    if (std.mem.startsWith(u8, path, "src/assets/")) rest = path["src/assets/".len..];
    if (std.mem.startsWith(u8, path, "src/styles/")) rest = path["src/styles/".len..];
    if (std.mem.startsWith(u8, path, "assets/")) rest = path["assets/".len..];
    if (std.mem.startsWith(u8, path, "styles/")) rest = path["styles/".len..];
    return try std.fmt.allocPrint(a, "theme/assets/{s} ({s} bytes copy; no fetch)", .{ rest, kind });
}

fn classifyFileRow(a: std.mem.Allocator, f: FileRec) !LedgerEntry {
    const path = f.path;
    const base = std.fs.path.basename(path);
    const ext = fileExtension(path);

    if (f.is_symlink) {
        return .{
            .source_path = path,
            .category = .other,
            .sha256 = "",
            .proposed_boris_equivalent = "(none — symlink rejected)",
            .decision = .drop,
            .reason = "symlink",
            .evidence = "theme inputs reject symlinks; inventory only, never followed",
            .unsupported_runtime = false,
        };
    }

    if (isLicenseName(base)) {
        return .{
            .source_path = path,
            .category = .license,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = "copy into theme provenance / LICENSE (human retain)",
            .decision = .preserve,
            .reason = "license_file",
            .evidence = "filename matches license/notice/copying",
            .unsupported_runtime = false,
        };
    }

    if (isLayoutPath(path)) {
        return .{
            .source_path = path,
            .category = .layout,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = try proposeLayoutEquivalent(a, path),
            .decision = .adapt,
            .reason = "astro_or_html_layout",
            .evidence = "path under layouts/",
            .unsupported_runtime = false,
        };
    }

    if (isPageTemplatePath(path)) {
        return .{
            .source_path = path,
            .category = .template,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = "not a theme layout; content/routes handled by content migration labs",
            .decision = .review,
            .reason = "page_route_template",
            .evidence = "src/pages/**.astro is routing, not theme ownership",
            .unsupported_runtime = false,
        };
    }

    if (isComponentPath(path)) {
        const runtime = isScriptExt(ext) and (asciiLowerEq(ext, ".tsx") or asciiLowerEq(ext, ".jsx") or
            asciiLowerEq(ext, ".vue") or asciiLowerEq(ext, ".svelte") or
            containsIgnoreCase(path, "island") or containsIgnoreCase(base, "react") or
            containsIgnoreCase(base, "vue") or containsIgnoreCase(base, "svelte"));
        if (runtime) {
            return .{
                .source_path = path,
                .category = .component,
                .sha256 = f.sha256,
                .proposed_boris_equivalent = "(none — no runtime component host)",
                .decision = .drop,
                .reason = "runtime_framework_component",
                .evidence = "extension/path indicates React/Vue/Svelte/island; never executed",
                .unsupported_runtime = true,
            };
        }
        // Astro components: map only when the basename is a known native tag; else review.
        var stem = base;
        if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
            if (dot > 0) stem = base[0..dot];
        }
        if (knownNativeTag(stem)) |equiv| {
            return .{
                .source_path = path,
                .category = .component,
                .sha256 = f.sha256,
                .proposed_boris_equivalent = equiv,
                .decision = .adapt,
                .reason = "known_native_component_candidate",
                .evidence = "component basename matches closed Aside/Details set",
                .unsupported_runtime = false,
            };
        }
        return .{
            .source_path = path,
            .category = .component,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = "(none closed — human component redesign or drop)",
            .decision = .review,
            .reason = "unsupported_or_unknown_component",
            .evidence = "component file without closed Boris mapping",
            .unsupported_runtime = false,
        };
    }

    if (isCssExt(ext) or (isSrcAssetPath(path) and isCssExt(ext)) or
        (isPublicPath(path) and isCssExt(ext)))
    {
        return .{
            .source_path = path,
            .category = .css,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = try proposeAssetEquivalent(a, path, "css"),
            .decision = .preserve,
            .reason = "static_stylesheet",
            .evidence = "css path; content scan may add remote/traversal rows",
            .unsupported_runtime = false,
        };
    }

    if (isFontExt(ext)) {
        return .{
            .source_path = path,
            .category = .font,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = try proposeAssetEquivalent(a, path, "font"),
            .decision = .preserve,
            .reason = "static_font",
            .evidence = "font extension under theme/public/assets tree",
            .unsupported_runtime = false,
        };
    }

    if (isImageExt(ext) and (isPublicPath(path) or isSrcAssetPath(path) or
        std.mem.startsWith(u8, path, "src/") or std.mem.indexOf(u8, path, "/images/") != null or
        std.mem.indexOf(u8, path, "/img/") != null))
    {
        return .{
            .source_path = path,
            .category = .image,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = try proposeAssetEquivalent(a, path, "image"),
            .decision = .preserve,
            .reason = "static_image",
            .evidence = "image asset path",
            .unsupported_runtime = false,
        };
    }

    if (isScriptExt(ext) and !isConfigPath(path) and !isComponentPath(path)) {
        // Theme-level scripts (public/scripts, src/scripts) — runtime.
        const under_theme = isPublicPath(path) or std.mem.startsWith(u8, path, "src/scripts/") or
            std.mem.startsWith(u8, path, "scripts/") or std.mem.indexOf(u8, path, "/scripts/") != null;
        if (under_theme or !std.mem.startsWith(u8, path, "src/content/")) {
            return .{
                .source_path = path,
                .category = .script,
                .sha256 = f.sha256,
                .proposed_boris_equivalent = "(none — no product JS runtime; optional trusted theme include only after human review)",
                .decision = .review,
                .reason = "script_file",
                .evidence = "script source file; never executed by this lab",
                .unsupported_runtime = true,
            };
        }
    }

    if (isConfigPath(path)) {
        return .{
            .source_path = path,
            .category = .config,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = "evidence only (sidebar/nav/deps); not a Boris config dialect",
            .decision = .review,
            .reason = "site_config",
            .evidence = "config filename; text-scanned, never evaluated",
            .unsupported_runtime = false,
        };
    }

    if (isContentPath(path)) {
        return .{
            .source_path = path,
            .category = .other,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = "content migration labs (astro/starlight); theme ledger records embedded tags only",
            .decision = .review,
            .reason = "content_page",
            .evidence = "markdown/mdx under content roots",
            .unsupported_runtime = false,
        };
    }

    // package-lock etc.
    if (asciiLowerEq(base, "package-lock.json") or asciiLowerEq(base, "pnpm-lock.yaml") or
        asciiLowerEq(base, "yarn.lock") or asciiLowerEq(base, "bun.lockb"))
    {
        return .{
            .source_path = path,
            .category = .provenance,
            .sha256 = f.sha256,
            .proposed_boris_equivalent = "(none — lockfile not imported)",
            .decision = .drop,
            .reason = "package_lock",
            .evidence = "dependency lockfile",
            .unsupported_runtime = false,
        };
    }

    return .{
        .source_path = path,
        .category = .other,
        .sha256 = f.sha256,
        .proposed_boris_equivalent = "(unclassified — human review)",
        .decision = .review,
        .reason = "unclassified_file",
        .evidence = "path/extension outside closed theme categories",
        .unsupported_runtime = false,
    };
}

/// Extract a quoted or bare token after a marker (best-effort text scan).
fn extractUrlish(line: []const u8) ?[]const u8 {
    // Prefer url(...) then quoted then bare http
    if (std.mem.indexOf(u8, line, "url(")) |u| {
        var i = u + 4;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i >= line.len) return null;
        if (line[i] == '"' or line[i] == '\'') {
            const q = line[i];
            i += 1;
            const start = i;
            while (i < line.len and line[i] != q) : (i += 1) {}
            if (i > start) return line[start..i];
        } else {
            const start = i;
            while (i < line.len and line[i] != ')' and line[i] != ' ' and line[i] != '\t') : (i += 1) {}
            if (i > start) return line[start..i];
        }
    }
    // href="..." or src="..."
    for ([_][]const u8{ "href=", "src=", "import " }) |key| {
        if (std.mem.indexOf(u8, line, key)) |p| {
            var i = p + key.len;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            if (i < line.len and (line[i] == '"' or line[i] == '\'')) {
                const q = line[i];
                i += 1;
                const start = i;
                while (i < line.len and line[i] != q) : (i += 1) {}
                if (i > start) return line[start..i];
            }
        }
    }
    if (std.mem.indexOf(u8, line, "https://")) |p| {
        var i = p;
        while (i < line.len and line[i] != ' ' and line[i] != '"' and line[i] != '\'' and
            line[i] != ')' and line[i] != ';' and line[i] != ',') : (i += 1)
        {}
        return line[p..i];
    }
    if (std.mem.indexOf(u8, line, "http://")) |p| {
        var i = p;
        while (i < line.len and line[i] != ' ' and line[i] != '"' and line[i] != '\'' and
            line[i] != ')' and line[i] != ';' and line[i] != ',') : (i += 1)
        {}
        return line[p..i];
    }
    return null;
}

fn scanPascalCaseTags(a: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]const u8)) !void {
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '<') continue;
        if (i + 1 >= line.len) break;
        if (line[i + 1] == '/' or line[i + 1] == '!' or line[i + 1] == '?') continue;
        const start = i + 1;
        if (start >= line.len) break;
        // PascalCase: first char uppercase letter
        if (!(line[start] >= 'A' and line[start] <= 'Z')) continue;
        var j = start + 1;
        while (j < line.len) {
            const c = line[j];
            const ok = (c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or
                (c >= '0' and c <= '9') or c == '_' or c == '.';
            if (!ok) break;
            j += 1;
        }
        if (j > start) {
            try out.append(a, try a.dupe(u8, line[start..j]));
        }
        i = j;
    }
}

fn scanFileContent(
    a: std.mem.Allocator,
    path: []const u8,
    data: []const u8,
    ledger: *std.ArrayList(LedgerEntry),
) !void {
    const ext = fileExtension(path);
    if (!isTextScanExt(ext) and !isConfigPath(path) and !isLicenseName(std.fs.path.basename(path))) return;

    // Cap scan size for pathological fixtures (still deterministic).
    const scan = if (data.len > 512 * 1024) data[0 .. 512 * 1024] else data;

    var pos: usize = 0;
    var line_no: usize = 1;
    var tags: std.ArrayList([]const u8) = .empty;

    while (pos < scan.len) {
        const end = std.mem.indexOfScalarPos(u8, scan, pos, '\n') orelse scan.len;
        const line = scan[pos..end];
        const s = trim(line);

        // Never follow directives — only inventory them as runtime/untrusted.
        if (std.mem.startsWith(u8, s, "<!--") and (containsIgnoreCase(s, "agent") or
            containsIgnoreCase(s, "instruction") or containsIgnoreCase(s, "system prompt") or
            containsIgnoreCase(s, "ignore previous")))
        {
            try ledger.append(a, .{
                .source_path = path,
                .category = .runtime_assumption,
                .sha256 = "",
                .proposed_boris_equivalent = "(none — embedded directive ignored)",
                .decision = .drop,
                .reason = "embedded_directive",
                .evidence = try std.fmt.allocPrint(a, "L{d}: directive-like comment not followed", .{line_no}),
                .unsupported_runtime = true,
            });
        }
        if (std.mem.startsWith(u8, s, ":::agent") or std.mem.startsWith(u8, s, "```agent") or
            std.mem.startsWith(u8, s, "```instruction") or std.mem.startsWith(u8, s, "```prompt"))
        {
            try ledger.append(a, .{
                .source_path = path,
                .category = .runtime_assumption,
                .sha256 = "",
                .proposed_boris_equivalent = "(none — untrusted fence ignored)",
                .decision = .drop,
                .reason = "untrusted_fence",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .unsupported_runtime = true,
            });
        }

        // CSS @import
        if (std.mem.indexOf(u8, s, "@import") != null) {
            const target = extractUrlish(s) orelse s;
            if (isRemoteUrl(target)) {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .css_import,
                    .sha256 = "",
                    .proposed_boris_equivalent = "(none — remote CSS never fetched)",
                    .decision = .drop,
                    .reason = "remote_css_import",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = true,
                });
            } else if (hasTraversal(target)) {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .css_import,
                    .sha256 = "",
                    .proposed_boris_equivalent = "(none — traversal refused)",
                    .decision = .drop,
                    .reason = "traversal_css_import",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = false,
                });
            } else {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .css_import,
                    .sha256 = "",
                    .proposed_boris_equivalent = "theme/assets/… local import (copy if present; else missing-asset review)",
                    .decision = .review,
                    .reason = "local_css_import",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = false,
                });
            }
        }

        // url(...) with remote or traversal (CSS / HTML)
        if (std.mem.indexOf(u8, s, "url(") != null) {
            if (extractUrlish(s)) |target| {
                if (isRemoteUrl(target)) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .external_url,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none — remote url() never fetched)",
                        .decision = .drop,
                        .reason = "remote_url_ref",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = true,
                    });
                } else if (hasTraversal(target)) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .other,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none — traversal refused)",
                        .decision = .drop,
                        .reason = "traversal_url_ref",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = false,
                    });
                }
            }
        }

        // <script …>
        if (containsIgnoreCase(s, "<script")) {
            const remote = extractUrlish(s);
            if (remote) |r| {
                if (isRemoteUrl(r)) {
                    const cat: Category = if (looksLikeAnalytics(r) or looksLikeAnalytics(s)) .analytics else .script;
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = cat,
                        .sha256 = "",
                        .proposed_boris_equivalent = "explicit trusted theme injection only after human design (never auto-copied remote)",
                        .decision = .review,
                        .reason = if (cat == .analytics) "remote_analytics_script" else "remote_script",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = true,
                    });
                } else {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .script,
                        .sha256 = "",
                        .proposed_boris_equivalent = "optional trusted theme asset after human review",
                        .decision = .review,
                        .reason = "local_script_tag",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = true,
                    });
                }
            } else {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .script,
                    .sha256 = "",
                    .proposed_boris_equivalent = "(none auto — inline script is runtime; human redesign)",
                    .decision = .drop,
                    .reason = "inline_script",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = true,
                });
            }
        }

        // client:* directives (Astro islands)
        if (std.mem.indexOf(u8, s, "client:") != null) {
            try ledger.append(a, .{
                .source_path = path,
                .category = .runtime_assumption,
                .sha256 = "",
                .proposed_boris_equivalent = "(none — no hydration runtime)",
                .decision = .drop,
                .reason = "astro_client_directive",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .unsupported_runtime = true,
            });
        }

        // import.meta.env / process.env
        if (std.mem.indexOf(u8, s, "import.meta.env") != null or std.mem.indexOf(u8, s, "process.env") != null) {
            try ledger.append(a, .{
                .source_path = path,
                .category = .runtime_assumption,
                .sha256 = "",
                .proposed_boris_equivalent = "(none — env-dependent runtime)",
                .decision = .drop,
                .reason = "env_runtime",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .unsupported_runtime = true,
            });
        }

        // link rel=stylesheet remote
        if (containsIgnoreCase(s, "rel=") and containsIgnoreCase(s, "stylesheet")) {
            if (extractUrlish(s)) |href| {
                if (isRemoteUrl(href)) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .css_import,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none — remote stylesheet never fetched)",
                        .decision = .drop,
                        .reason = "remote_stylesheet_link",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = true,
                    });
                } else if (hasTraversal(href)) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .css_import,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none — traversal refused)",
                        .decision = .drop,
                        .reason = "traversal_stylesheet_link",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = false,
                    });
                }
            }
        }

        // Analytics identifiers even without <script
        if (looksLikeAnalytics(s) and std.mem.indexOf(u8, s, "http") != null) {
            try ledger.append(a, .{
                .source_path = path,
                .category = .analytics,
                .sha256 = "",
                .proposed_boris_equivalent = "explicit theme/deploy choice only (see docs/MIGRATION.md analytics section)",
                .decision = .review,
                .reason = "analytics_reference",
                .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                .unsupported_runtime = true,
            });
        }

        // Sidebar / nav evidence in config
        if (isConfigPath(path) or std.mem.startsWith(u8, std.fs.path.basename(path), "astro.config.")) {
            if (std.mem.indexOf(u8, s, "sidebar") != null or std.mem.indexOf(u8, s, "autogenerate") != null or
                std.mem.indexOf(u8, s, "slug:") != null and std.mem.indexOf(u8, path, "astro.config") != null)
            {
                // Record each nav-ish line once via broader checks below
            }
            if (std.mem.indexOf(u8, s, "sidebar") != null) {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .navigation,
                    .sha256 = "",
                    .proposed_boris_equivalent = "{{nav}} from Trunk/Satellite graph (human graph design; no sidebar dialect)",
                    .decision = .review,
                    .reason = "sidebar_config",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = false,
                });
            } else if (std.mem.indexOf(u8, s, "autogenerate") != null) {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .navigation,
                    .sha256 = "",
                    .proposed_boris_equivalent = "directory → Trunk + Satellites (one-level forest; human confirm)",
                    .decision = .review,
                    .reason = "sidebar_autogenerate",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = false,
                });
            } else if (std.mem.indexOf(u8, s, "slug:") != null and std.mem.indexOf(u8, path, "astro.config") != null) {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .navigation,
                    .sha256 = "",
                    .proposed_boris_equivalent = "map slug to entity id when in converted slice; else review",
                    .decision = .review,
                    .reason = "sidebar_slug",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = false,
                });
            } else if (std.mem.indexOf(u8, s, "\"license\"") != null or std.mem.indexOf(u8, s, "'license'") != null or
                std.mem.indexOf(u8, s, "license:") != null)
            {
                if (asciiLowerEq(std.fs.path.basename(path), "package.json")) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .provenance,
                        .sha256 = "",
                        .proposed_boris_equivalent = "record license field in theme provenance notes",
                        .decision = .preserve,
                        .reason = "package_json_license",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = false,
                    });
                }
            }
        }

        // MDX / Astro component tags in content and components
        if (std.mem.endsWith(u8, path, ".mdx") or std.mem.endsWith(u8, path, ".md") or
            std.mem.endsWith(u8, path, ".astro"))
        {
            tags.clearRetainingCapacity();
            try scanPascalCaseTags(a, s, &tags);
            for (tags.items) |tag| {
                // Skip HTML builtins that are PascalCase-false (none) — we only catch PascalCase
                if (knownNativeTag(tag)) |equiv| {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .mdx_tag,
                        .sha256 = "",
                        .proposed_boris_equivalent = equiv,
                        .decision = .adapt,
                        .reason = "known_native_mdx_tag",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: <{s}>", .{ line_no, tag }),
                        .unsupported_runtime = false,
                    });
                } else {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .mdx_tag,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none closed — unsupported component tag)",
                        .decision = .review,
                        .reason = "unsupported_mdx_tag",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: <{s}>", .{ line_no, tag }),
                        .unsupported_runtime = false,
                    });
                }
            }
            // MDX import lines
            if (std.mem.startsWith(u8, s, "import ")) {
                try ledger.append(a, .{
                    .source_path = path,
                    .category = .runtime_assumption,
                    .sha256 = "",
                    .proposed_boris_equivalent = "(none — import not executed; content labs strip imports)",
                    .decision = .review,
                    .reason = "mdx_or_esm_import",
                    .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                    .unsupported_runtime = true,
                });
            }
        }

        // Markdown image/link traversal
        if (std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".mdx")) {
            if (std.mem.indexOf(u8, s, "](")) |br| {
                const after = s[br + 2 ..];
                const close = std.mem.indexOfScalar(u8, after, ')') orelse after.len;
                const dest = after[0..close];
                if (hasTraversal(dest)) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .other,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none — traversal destination refused)",
                        .decision = .drop,
                        .reason = "traversal_markdown_ref",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = false,
                    });
                } else if (isRemoteUrl(dest)) {
                    try ledger.append(a, .{
                        .source_path = path,
                        .category = .external_url,
                        .sha256 = "",
                        .proposed_boris_equivalent = "(none — remote markdown ref not fetched)",
                        .decision = .review,
                        .reason = "remote_markdown_ref",
                        .evidence = try std.fmt.allocPrint(a, "L{d}: {s}", .{ line_no, s }),
                        .unsupported_runtime = true,
                    });
                }
            }
        }

        pos = if (end < scan.len) end + 1 else end;
        line_no += 1;
    }
}

fn detectDuplicateAssets(a: std.mem.Allocator, files: []const FileRec, ledger: *std.ArrayList(LedgerEntry)) !void {
    // Group by sha256 (non-empty) for content duplicates; also group by basename for name collisions.
    var by_hash: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var by_base: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;

    for (files) |f| {
        if (f.is_symlink or f.sha256.len == 0) continue;
        const ext = fileExtension(f.path);
        const asset_like = isImageExt(ext) or isFontExt(ext) or isCssExt(ext);
        if (!asset_like) continue;

        const gop = try by_hash.getOrPut(a, f.sha256);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(a, f.path);

        const base = std.fs.path.basename(f.path);
        const gop2 = try by_base.getOrPut(a, base);
        if (!gop2.found_existing) gop2.value_ptr.* = .empty;
        try gop2.value_ptr.append(a, f.path);
    }

    var hit = by_hash.iterator();
    while (hit.next()) |e| {
        if (e.value_ptr.items.len < 2) continue;
        // sort paths for deterministic evidence
        std.mem.sort([]const u8, e.value_ptr.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        var detail: std.ArrayList(u8) = .empty;
        for (e.value_ptr.items, 0..) |p, i| {
            if (i > 0) try detail.appendSlice(a, ", ");
            try detail.appendSlice(a, p);
        }
        try ledger.append(a, .{
            .source_path = e.value_ptr.items[0],
            .category = .image,
            .sha256 = e.key_ptr.*,
            .proposed_boris_equivalent = "dedupe into single theme/assets path (human choose canonical)",
            .decision = .review,
            .reason = "duplicate_content_hash",
            .evidence = try std.fmt.allocPrint(a, "identical sha256 across: {s}", .{detail.items}),
            .unsupported_runtime = false,
        });
    }

    var bit = by_base.iterator();
    while (bit.next()) |e| {
        if (e.value_ptr.items.len < 2) continue;
        std.mem.sort([]const u8, e.value_ptr.items, {}, struct {
            fn less(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.less);
        // Skip if already same-hash group only (still report basename clash across dirs)
        var detail: std.ArrayList(u8) = .empty;
        for (e.value_ptr.items, 0..) |p, i| {
            if (i > 0) try detail.appendSlice(a, ", ");
            try detail.appendSlice(a, p);
        }
        try ledger.append(a, .{
            .source_path = e.value_ptr.items[0],
            .category = .image,
            .sha256 = "",
            .proposed_boris_equivalent = "disambiguate theme asset names (no silent overwrite)",
            .decision = .review,
            .reason = "duplicate_basename",
            .evidence = try std.fmt.allocPrint(a, "basename `{s}` at: {s}", .{ e.key_ptr.*, detail.items }),
            .unsupported_runtime = false,
        });
    }
}

fn sortLedger(entries: []LedgerEntry) void {
    std.mem.sort(LedgerEntry, entries, {}, struct {
        fn less(_: void, x: LedgerEntry, y: LedgerEntry) bool {
            const p = std.mem.order(u8, x.source_path, y.source_path);
            if (p != .eq) return p == .lt;
            const c = std.mem.order(u8, x.category.jsonName(), y.category.jsonName());
            if (c != .eq) return c == .lt;
            const d = std.mem.order(u8, x.decision.jsonName(), y.decision.jsonName());
            if (d != .eq) return d == .lt;
            const r = std.mem.order(u8, x.reason, y.reason);
            if (r != .eq) return r == .lt;
            return std.mem.order(u8, x.evidence, y.evidence) == .lt;
        }
    }.less);
}

// ---------------------------------------------------------------------------
// Emit
// ---------------------------------------------------------------------------

fn countDecisions(entries: []const LedgerEntry, d: Decision) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.decision == d) n += 1;
    }
    return n;
}

fn countCategory(entries: []const LedgerEntry, c: Category) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.category == c) n += 1;
    }
    return n;
}

fn countUnsupported(entries: []const LedgerEntry) usize {
    var n: usize = 0;
    for (entries) |e| {
        if (e.unsupported_runtime) n += 1;
    }
    return n;
}

fn emitLedgerJson(a: std.mem.Allocator, source_root: []const u8, entries: []const LedgerEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": \"");
    try buf.appendSlice(a, format_id);
    try buf.appendSlice(a, "\",\n  \"schema_version\": ");
    try appendUsize(&buf, a, schema_version);
    try buf.appendSlice(a, ",\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, source_root);
    try buf.appendSlice(a,
        \\,
        \\  "policy": {
        \\    "source_readonly": true,
        \\    "remote_fetch": false,
        \\    "execute_js": false,
        \\    "execute_mdx": false,
        \\    "follow_directives": false,
        \\    "ambiguous_mappings": "review",
        \\    "guess_mappings": false
        \\  },
        \\  "entries": [
        \\
    );
    for (entries, 0..) |e, i| {
        try buf.appendSlice(a, "    { \"source_path\": ");
        try appendJson(&buf, a, e.source_path);
        try buf.appendSlice(a, ", \"category\": ");
        try appendJson(&buf, a, e.category.jsonName());
        try buf.appendSlice(a, ", \"sha256\": ");
        if (e.sha256.len > 0) try appendJson(&buf, a, e.sha256) else try buf.appendSlice(a, "null");
        try buf.appendSlice(a, ", \"proposed_boris_equivalent\": ");
        try appendJson(&buf, a, e.proposed_boris_equivalent);
        try buf.appendSlice(a, ", \"decision\": ");
        try appendJson(&buf, a, e.decision.jsonName());
        try buf.appendSlice(a, ", \"reason\": ");
        try appendJson(&buf, a, e.reason);
        try buf.appendSlice(a, ", \"evidence\": ");
        try appendJson(&buf, a, e.evidence);
        try buf.appendSlice(a, ", \"unsupported_runtime\": ");
        try appendBool(&buf, a, e.unsupported_runtime);
        try buf.appendSlice(a, " }");
        if (i + 1 < entries.len) try buf.append(a, ',');
        try buf.append(a, '\n');
    }
    try buf.appendSlice(a, "  ]\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportJson(a: std.mem.Allocator, source_root: []const u8, entries: []const LedgerEntry, file_count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a, "{\n  \"format\": \"");
    try buf.appendSlice(a, format_id);
    try buf.appendSlice(a, "\",\n  \"schema_version\": ");
    try appendUsize(&buf, a, schema_version);
    try buf.appendSlice(a, ",\n  \"tool_version\": ");
    try appendJson(&buf, a, tool_version);
    try buf.appendSlice(a, ",\n  \"source_root\": ");
    try appendJson(&buf, a, source_root);
    try buf.appendSlice(a, ",\n  \"counts\": {\n    \"files_inventoried\": ");
    try appendUsize(&buf, a, file_count);
    try buf.appendSlice(a, ",\n    \"ledger_entries\": ");
    try appendUsize(&buf, a, entries.len);
    try buf.appendSlice(a, ",\n    \"preserve\": ");
    try appendUsize(&buf, a, countDecisions(entries, .preserve));
    try buf.appendSlice(a, ",\n    \"adapt\": ");
    try appendUsize(&buf, a, countDecisions(entries, .adapt));
    try buf.appendSlice(a, ",\n    \"review\": ");
    try appendUsize(&buf, a, countDecisions(entries, .review));
    try buf.appendSlice(a, ",\n    \"drop\": ");
    try appendUsize(&buf, a, countDecisions(entries, .drop));
    try buf.appendSlice(a, ",\n    \"unsupported_runtime\": ");
    try appendUsize(&buf, a, countUnsupported(entries));
    try buf.appendSlice(a, ",\n    \"layouts\": ");
    try appendUsize(&buf, a, countCategory(entries, .layout));
    try buf.appendSlice(a, ",\n    \"css\": ");
    try appendUsize(&buf, a, countCategory(entries, .css));
    try buf.appendSlice(a, ",\n    \"components\": ");
    try appendUsize(&buf, a, countCategory(entries, .component));
    try buf.appendSlice(a, ",\n    \"mdx_tags\": ");
    try appendUsize(&buf, a, countCategory(entries, .mdx_tag));
    try buf.appendSlice(a, ",\n    \"navigation\": ");
    try appendUsize(&buf, a, countCategory(entries, .navigation));
    try buf.appendSlice(a, ",\n    \"scripts\": ");
    try appendUsize(&buf, a, countCategory(entries, .script));
    try buf.appendSlice(a, ",\n    \"analytics\": ");
    try appendUsize(&buf, a, countCategory(entries, .analytics));
    try buf.appendSlice(a, ",\n    \"licenses\": ");
    try appendUsize(&buf, a, countCategory(entries, .license));
    try buf.appendSlice(a, "\n  },\n  \"policy\": {\n    \"source_readonly\": true,\n    \"remote_fetch\": false,\n    \"execute_js\": false,\n    \"execute_mdx\": false,\n    \"follow_directives\": false,\n    \"guess_mappings\": false\n  }\n}\n");
    return try buf.toOwnedSlice(a);
}

fn emitReportMd(a: std.mem.Allocator, entries: []const LedgerEntry, file_count: usize) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a,
        \\# Theme archaeology report
        \\
        \\Read-only inventory of an Astro/Starlight-shaped theme. Source tree is
        \\never modified. JavaScript and MDX are never executed. Remote assets are
        \\never fetched. Ambiguous mappings are **review**, never guesses.
        \\
        \\| metric | count |
        \\|---|---:|
        \\
    );
    try buf.appendSlice(a, "| files inventoried | ");
    try appendUsize(&buf, a, file_count);
    try buf.appendSlice(a, " |\n| ledger entries | ");
    try appendUsize(&buf, a, entries.len);
    try buf.appendSlice(a, " |\n| preserve | ");
    try appendUsize(&buf, a, countDecisions(entries, .preserve));
    try buf.appendSlice(a, " |\n| adapt | ");
    try appendUsize(&buf, a, countDecisions(entries, .adapt));
    try buf.appendSlice(a, " |\n| review | ");
    try appendUsize(&buf, a, countDecisions(entries, .review));
    try buf.appendSlice(a, " |\n| drop | ");
    try appendUsize(&buf, a, countDecisions(entries, .drop));
    try buf.appendSlice(a, " |\n| unsupported_runtime | ");
    try appendUsize(&buf, a, countUnsupported(entries));
    try buf.appendSlice(a, " |\n\n## Ledger (summary)\n\n");
    for (entries) |e| {
        try buf.appendSlice(a, "- `");
        try buf.appendSlice(a, e.source_path);
        try buf.appendSlice(a, "` · ");
        try buf.appendSlice(a, e.category.jsonName());
        try buf.appendSlice(a, " · **");
        try buf.appendSlice(a, e.decision.jsonName());
        try buf.appendSlice(a, "** · ");
        try buf.appendSlice(a, e.reason);
        if (e.unsupported_runtime) try buf.appendSlice(a, " · runtime");
        try buf.appendSlice(a, "\n  - boris: ");
        try buf.appendSlice(a, e.proposed_boris_equivalent);
        try buf.appendSlice(a, "\n  - evidence: ");
        try buf.appendSlice(a, e.evidence);
        if (e.sha256.len > 0) {
            try buf.appendSlice(a, "\n  - sha256: `");
            try buf.appendSlice(a, e.sha256);
            try buf.appendSlice(a, "`");
        }
        try buf.appendSlice(a, "\n");
    }
    try buf.appendSlice(a,
        \\
        \\Machine-readable twins: `adaptation_ledger.json`, `report.json`, `BOUNDARY.md`.
        \\
    );
    return try buf.toOwnedSlice(a);
}

fn emitBoundaryReport(a: std.mem.Allocator, entries: []const LedgerEntry) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(a);
    try buf.appendSlice(a,
        \\# Theme conversion boundary report
        \\
        \\This document is the hard boundary between what a **future theme converter**
        \\could safely generate from this archaeology ledger and what still requires
        \\**human design work**. It is produced by the migration laboratory only —
        \\not by the Boris product compiler.
        \\
        \\## Safety invariants (always)
        \\
        \\1. Source theme tree is read-only; converter outputs write only under `--out`.
        \\2. Never execute source-site JavaScript, TypeScript, MDX, Vue, Svelte, or islands.
        \\3. Never fetch remote CSS, fonts, scripts, or images.
        \\4. Never follow embedded agent/prompt/instruction directives in content.
        \\5. Never guess component or layout semantics; unknown → `review`.
        \\6. Symlinks and path traversal (`..`) are refused, not followed.
        \\7. Repeated converter runs on the same inputs must be byte-identical.
        \\
        \\## What a future converter could safely generate
        \\
        \\From **preserve** / closed **adapt** rows only:
        \\
        \\| Source signal | Safe generation |
        \\|---|---|
        \\| Static CSS without remote/traversal imports | `theme/assets/css/**` byte copy |
        \\| Fonts (woff/woff2/ttf/otf) | `theme/assets/fonts/**` byte copy |
        \\| Images under `public/` / `src/assets/` | `theme/assets/**` byte copy |
        \\| LICENSE / NOTICE / package.json license field | Provenance notes + optional LICENSE copy |
        \\| Layout shells without scripts/islands | Draft `theme/layouts/*.html` with closed slots (`{{content}}`, `{{title}}`, `{{nav}}`, `{{toc}}`, `{{breadcrumb}}`, `{{children}}`, `{{metadata}}`, `{{footer}}`, `{{asset-url …}}`) — **structure only**, no expression language |
        \\| Known admonition tags (`Aside`, `Note`, `Tip`, `Caution`, `Warning`, `Danger`, `Callout`) | Suggest native `<Aside>` kind mapping table for human confirm |
        \\| Known `Details` tags | Suggest native `<Details>` |
        \\
        \\All generated layout HTML must remain trusted static templates (no conditionals,
        \\loops, or JS). Asset paths must satisfy Boris theme path rules (no `..`, no
        \\absolute, no symlinks).
        \\
        \\## What still requires human design work
        \\
        \\| Signal | Why automatic conversion is unsafe |
        \\|---|---|
        \\| Starlight/Astro `sidebar` / `autogenerate` | Nav is a product graph (Trunk/Satellite), not a sidebar dialect |
        \\| Unknown MDX / Astro components (`Card`, `Tabs`, `Steps`, custom widgets) | No closed semantic mapping; inventing HTML would lie |
        \\| React/Vue/Svelte islands and `client:*` | Boris has no hydration runtime |
        \\| Inline / remote `<script>` and analytics beacons | Explicit theme or deploy choice; privacy and trust |
        \\| Remote `@import` / CDN stylesheets | Never fetched; offline and supply-chain boundary |
        \\| `import.meta.env` / `process.env` | Build-time runtime assumptions |
        \\| Page routes under `src/pages/` | Content/route migration, not theme ownership |
        \\| Duplicate asset hashes / basenames | Human picks canonical path; no silent overwrite |
        \\| SCSS/Sass/Less toolchains | No product CSS preprocessor pipeline |
        \\| Tailwind / PostCSS config | Design-system decision, not a mechanical rewrite |
        \\
        \\## Unsupported / runtime-dependent behavior (this run)
        \\
        \\
    );

    var any_runtime = false;
    for (entries) |e| {
        if (!e.unsupported_runtime) continue;
        any_runtime = true;
        try buf.appendSlice(a, "- `");
        try buf.appendSlice(a, e.source_path);
        try buf.appendSlice(a, "` — ");
        try buf.appendSlice(a, e.reason);
        try buf.appendSlice(a, " (");
        try buf.appendSlice(a, e.decision.jsonName());
        try buf.appendSlice(a, "): ");
        try buf.appendSlice(a, e.evidence);
        try buf.appendSlice(a, "\n");
    }
    if (!any_runtime) {
        try buf.appendSlice(a, "_No unsupported_runtime rows in this ledger._\n");
    }

    try buf.appendSlice(a,
        \\
        \\## Decision legend
        \\
        \\| Decision | Meaning |
        \\|---|---|
        \\| `preserve` | Static bytes / provenance can transfer without reinterpretation |
        \\| `adapt` | Closed mechanical mapping exists; still verify slots/kinds |
        \\| `review` | Ambiguous or multi-valid mapping — human required |
        \\| `drop` | Out of product scope, unsafe, or refused (remote/traversal/runtime) |
        \\
        \\## Out of scope for theme archaeology
        \\
        \\- Content body migration (use `astro` / `starlight` / other content labs)
        \\- Graph validation, IR emit, or HTML compile (use product `boris`)
        \\- Installing npm packages, running Astro, or evaluating config modules
        \\- Pixel-perfect visual parity claims
        \\
        \\Companion ledger: `adaptation_ledger.json`. Summary: `REPORT.md` / `report.json`.
        \\
    );
    return try buf.toOwnedSlice(a);
}

// ---------------------------------------------------------------------------
// run
// ---------------------------------------------------------------------------

pub fn run(io: Io, gpa: std.mem.Allocator, opts: Options) !void {
    try refuseOutputInsideSource(opts.root_dir, opts.out_dir);

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const a = arena.allocator();

    var root = Io.Dir.cwd().openDir(io, opts.root_dir, .{}) catch return error.SourceNotFound;
    defer root.close(io);

    var files: std.ArrayList(FileRec) = .empty;
    try walkTree(io, a, root, "", &files);
    std.mem.sort(FileRec, files.items, {}, struct {
        fn less(_: void, x: FileRec, y: FileRec) bool {
            return std.mem.order(u8, x.path, y.path) == .lt;
        }
    }.less);

    var ledger: std.ArrayList(LedgerEntry) = .empty;

    // File-level inventory rows
    for (files.items) |f| {
        try ledger.append(a, try classifyFileRow(a, f));
    }

    // Content scans (re-read; arena-backed)
    for (files.items) |f| {
        if (f.is_symlink) continue;
        const ext = fileExtension(f.path);
        if (!isTextScanExt(ext) and !isConfigPath(f.path) and !isLicenseName(std.fs.path.basename(f.path))) continue;
        const data = readFileAlloc(io, root, f.path, a) catch continue;
        try scanFileContent(a, f.path, data, &ledger);
    }

    try detectDuplicateAssets(a, files.items, &ledger);

    sortLedger(ledger.items);

    Io.Dir.cwd().createDirPath(io, opts.out_dir) catch return error.IoFailure;
    var out_root = try Io.Dir.cwd().openDir(io, opts.out_dir, .{});
    defer out_root.close(io);

    const ledger_json = try emitLedgerJson(a, opts.root_dir, ledger.items);
    try writeBytes(io, out_root, "adaptation_ledger.json", ledger_json);
    const report_json = try emitReportJson(a, opts.root_dir, ledger.items, files.items.len);
    try writeBytes(io, out_root, "report.json", report_json);
    const report_md = try emitReportMd(a, ledger.items, files.items.len);
    try writeBytes(io, out_root, "REPORT.md", report_md);
    const boundary = try emitBoundaryReport(a, ledger.items);
    try writeBytes(io, out_root, "BOUNDARY.md", boundary);

    if (!opts.quiet) {
        std.debug.print(
            "theme-archaeology-lab: wrote {s}/adaptation_ledger.json, report.json, REPORT.md, BOUNDARY.md ({d} files, {d} ledger rows)\n",
            .{ opts.out_dir, files.items.len, ledger.items.len },
        );
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "refuseOutputInsideSource" {
    try refuseOutputInsideSource("a", "b");
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("a", "a"));
    try std.testing.expectError(error.OutputInsideSource, refuseOutputInsideSource("root", "root/out"));
}

test "hasTraversal and isRemoteUrl" {
    try std.testing.expect(hasTraversal("../x"));
    try std.testing.expect(hasTraversal("a/../../b"));
    try std.testing.expect(hasTraversal("foo/../bar"));
    try std.testing.expect(!hasTraversal("foo/bar"));
    try std.testing.expect(isRemoteUrl("https://cdn.example/x.css"));
    try std.testing.expect(isRemoteUrl("//cdn.example/x.css"));
    try std.testing.expect(!isRemoteUrl("./local.css"));
}

test "knownNativeTag closed set" {
    try std.testing.expect(knownNativeTag("Aside") != null);
    try std.testing.expect(knownNativeTag("Tip") != null);
    try std.testing.expect(knownNativeTag("Details") != null);
    try std.testing.expect(knownNativeTag("Card") == null);
    try std.testing.expect(knownNativeTag("Tabs") == null);
}

test "fixture mini-theme-astro: ledger shape and determinism" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/mini-theme-astro";
    const out_a = "fixtures/.tmp-theme-arch-mini-a";
    const out_b = "fixtures/.tmp-theme-arch-mini-b";
    Io.Dir.cwd().deleteTree(io, out_a) catch {};
    Io.Dir.cwd().deleteTree(io, out_b) catch {};
    defer {
        Io.Dir.cwd().deleteTree(io, out_a) catch {};
        Io.Dir.cwd().deleteTree(io, out_b) catch {};
    }

    // Source immutability probe
    const license_before = blk: {
        var d = try Io.Dir.cwd().openDir(io, root, .{});
        defer d.close(io);
        break :blk try readFileAlloc(io, d, "LICENSE", gpa);
    };
    defer gpa.free(license_before);

    try run(io, gpa, .{ .root_dir = root, .out_dir = out_a, .quiet = true });
    try run(io, gpa, .{ .root_dir = root, .out_dir = out_b, .quiet = true });

    var da = try Io.Dir.cwd().openDir(io, out_a, .{});
    defer da.close(io);
    var db = try Io.Dir.cwd().openDir(io, out_b, .{});
    defer db.close(io);

    const names = [_][]const u8{ "adaptation_ledger.json", "report.json", "REPORT.md", "BOUNDARY.md" };
    for (names) |n| {
        const aa = try readFileAlloc(io, da, n, gpa);
        defer gpa.free(aa);
        const bb = try readFileAlloc(io, db, n, gpa);
        defer gpa.free(bb);
        try std.testing.expectEqualStrings(aa, bb);
    }

    const ledger = try readFileAlloc(io, da, "adaptation_ledger.json", gpa);
    defer gpa.free(ledger);
    try std.testing.expect(std.mem.indexOf(u8, ledger, format_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"decision\": \"preserve\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"category\": \"layout\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"category\": \"css\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"category\": \"font\"") != null or
        std.mem.indexOf(u8, ledger, "\"category\": \"image\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"category\": \"navigation\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"category\": \"license\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "sha256") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "execute_js") != null);

    const boundary = try readFileAlloc(io, da, "BOUNDARY.md", gpa);
    defer gpa.free(boundary);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "What a future converter could safely generate") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "What still requires human design work") != null);

    const license_after = blk: {
        var d = try Io.Dir.cwd().openDir(io, root, .{});
        defer d.close(io);
        break :blk try readFileAlloc(io, d, "LICENSE", gpa);
    };
    defer gpa.free(license_after);
    try std.testing.expectEqualStrings(license_before, license_after);
}

test "fixture hostile-theme-astro: runtime, remote css, duplicates, unsupported, traversal" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    const root = "fixtures/hostile-theme-astro";
    const out = "fixtures/.tmp-theme-arch-hostile";
    Io.Dir.cwd().deleteTree(io, out) catch {};
    defer Io.Dir.cwd().deleteTree(io, out) catch {};

    try run(io, gpa, .{ .root_dir = root, .out_dir = out, .quiet = true });

    var d = try Io.Dir.cwd().openDir(io, out, .{});
    defer d.close(io);
    const ledger = try readFileAlloc(io, d, "adaptation_ledger.json", gpa);
    defer gpa.free(ledger);
    const report = try readFileAlloc(io, d, "report.json", gpa);
    defer gpa.free(report);
    const boundary = try readFileAlloc(io, d, "BOUNDARY.md", gpa);
    defer gpa.free(boundary);

    // Runtime scripts / client directives
    try std.testing.expect(std.mem.indexOf(u8, ledger, "astro_client_directive") != null or
        std.mem.indexOf(u8, ledger, "inline_script") != null or
        std.mem.indexOf(u8, ledger, "remote_script") != null);
    try std.testing.expect(std.mem.indexOf(u8, ledger, "\"unsupported_runtime\": true") != null);

    // Remote CSS
    try std.testing.expect(std.mem.indexOf(u8, ledger, "remote_css_import") != null or
        std.mem.indexOf(u8, ledger, "remote_stylesheet_link") != null or
        std.mem.indexOf(u8, ledger, "remote_url_ref") != null);

    // Duplicate assets
    try std.testing.expect(std.mem.indexOf(u8, ledger, "duplicate_content_hash") != null or
        std.mem.indexOf(u8, ledger, "duplicate_basename") != null);

    // Unsupported components / MDX tags
    try std.testing.expect(std.mem.indexOf(u8, ledger, "unsupported_mdx_tag") != null or
        std.mem.indexOf(u8, ledger, "unsupported_or_unknown_component") != null or
        std.mem.indexOf(u8, ledger, "runtime_framework_component") != null);

    // Path traversal
    try std.testing.expect(std.mem.indexOf(u8, ledger, "traversal_") != null);

    // Analytics / env
    try std.testing.expect(std.mem.indexOf(u8, ledger, "analytics") != null or
        std.mem.indexOf(u8, ledger, "env_runtime") != null);

    // Directives never followed — inventoried as drop
    try std.testing.expect(std.mem.indexOf(u8, ledger, "embedded_directive") != null or
        std.mem.indexOf(u8, ledger, "untrusted_fence") != null);

    try std.testing.expect(std.mem.indexOf(u8, report, "\"drop\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, boundary, "Never fetch remote") != null or
        std.mem.indexOf(u8, boundary, "never fetch") != null or
        std.mem.indexOf(u8, boundary, "Never fetch") != null);
}
