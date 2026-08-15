//! Structured diagnostics for the content compiler.
//!
//! Code strings match `docs/contracts/diagnostics.md` exactly (no underscore
//! variants). Strings inside a Diagnostic are owned by the caller's retain
//! allocator (typically the long-lived arena for a compile run).

const std = @import("std");
const parser = @import("parser.zig");

pub const Severity = enum {
    error_,
    warning,
    info,

    pub fn jsonName(self: Severity) []const u8 {
        return switch (self) {
            .error_ => "error",
            .warning => "warning",
            .info => "info",
        };
    }

    pub fn textName(self: Severity) []const u8 {
        return self.jsonName();
    }
};

/// Closed diagnostic codes (normative: docs/contracts/diagnostics.md).
pub const Code = enum {
    EDUPLICATEID,
    EPARENTMISSING,
    EPARENTSELF,
    /// Retired compatibility name for historical one-hop validation; current
    /// graph validation never emits this code.
    EPARENTNOTTRUNK,
    EPARENTCYCLE,
    EFRONTMATTER,
    EINVALIDUTF8,
    EINVALIDPATH,
    /// Source contains an invisible or non-interchange Unicode code point.
    /// Error for the reject tier; warning for the dual-use tier.
    EUNICODE,
    /// Explicit Textile-mode adapter failures and input-family mismatches.
    ETEXTILE,
    /// Explicit Cooklang-mode adapter failures and input-family mismatches.
    ECOOKLANG,
    /// Aside / registered-component tokenizer failures (milestone 10).
    ECOMPONENT,
    /// Malformed `{{include …}}` directive.
    EINCLUDESYNTAX,
    /// Include target path not found / unreadable.
    EINCLUDEMISSING,
    /// Transclusion cycle among includes.
    EINCLUDECYCLE,
    /// Malformed `[[…]]` wiki-link.
    EREFERENCESYNTAX,
    /// Wiki-link target entity id not in the page graph.
    EREFERENCEMISSING,
    /// Semantic relation target is not a discovered page.
    ERELATIONMISSING,
    /// Semantic relation points from a page to itself.
    ERELATIONSELF,
    /// Semantic relation tuple is repeated.
    ERELATIONDUPLICATE,
    /// Content-local page asset path/missing/symlink/collision failures.
    EASSET,
    /// Published local `href`/`src` resolves to no output this build keeps.
    EROUTEMISSING,
    /// Published local `href`/`src` climbs above the output root.
    EROUTEESCAPE,
    /// A rendered publication URL does not belong to the declared public
    /// origin/base-path, or a project-site root-relative route omits it.
    EPUBLICATIONLOCATION,
    /// Reserved: published reference resolves but its `#fragment` is not an id
    /// on the target page. Not yet emitted; see `link_audit.zig`.
    EFRAGMENTMISSING,
    /// A selected Nostr article is not publishable: wrong source dialect,
    /// draft, path-derived entity id, or missing required metadata.
    ENOSTRELIGIBILITY,
    /// A selected Nostr article's publication-safe Markdown view is refused:
    /// raw HTML, hard-wrapped prose, a Boris-only component, or a reference
    /// that does not resolve to a canonical URL.
    ENOSTRMARKDOWN,
    /// A Nostr article's `published_at` does not convert to a representable
    /// Unix timestamp.
    ENOSTRTIME,
    /// Reserved: a Nostr relay rejects an event, times out, or demands
    /// authentication. Not yet emitted — relay *configuration* is refused by
    /// the strict profile parser before any content is read, so this code
    /// belongs to the publish slice, where a relay is a live endpoint.
    ENOSTRRELAY,
    /// A Nostr publication plan cannot be built because the corpus changed
    /// under the run: a selected source no longer parses after the graph
    /// validated.
    ENOSTRPLAN,
    /// Layout template lacks a required or declared slot marker (or names an
    /// unknown marker).
    ELAYOUTMISSINGMARKER,
    /// Layout template repeats a slot marker.
    ELAYOUTDUPLICATEMARKER,
    /// Layout path is illegal (absolute, `..`, or otherwise non-relative).
    ELAYOUTPATH,
    /// Layout template references an invalid or excessive asset url.
    ELAYOUTASSET,
    /// Layout-rule selection failure (ambiguous glob, duplicate/invalid
    /// selector, or rule bounds).
    ELAYOUTRULE,
    /// Generic layout failure (structural bounds, invalid utf-8, …).
    ELAYOUT,
    /// Informational: a layout rule (id/glob/role selector) selected a
    /// non-fallback layout for a page. Records the selection outcome for
    /// editors/tools; never affects exit codes or errorCount.
    ILAYOUTSELECTED,

    EUSAGE,
    EIO,

    pub fn remediationForLayout(code: Code) []const u8 {
        return switch (code) {
            .ELAYOUTMISSINGMARKER => "Add the required {{content}} (and any other referenced slot) marker to the layout template",
            .ELAYOUTDUPLICATEMARKER => "Keep exactly one marker per slot in the layout template",
            .ELAYOUTPATH => "Use a workspace-relative layout path with no .., absolute, or backslash segments",
            .ELAYOUTASSET => "Reference layout assets as assets/… urls relative to the theme root, one per slot",
            .ELAYOUTRULE => "Give each layout rule a unique, valid selector and stay under the per-target rule limit",
            else => "Fix the layout template and retry the build",
        };
    }

    pub fn name(self: Code) []const u8 {
        return @tagName(self);
    }
};

/// Convert the parser's closed categories to the shared diagnostic codes.
/// Keeping this mapping here lets every product path preserve parser detail.
pub fn parserCategoryToCode(cat: parser.Category) Code {
    return switch (cat) {
        .EFRONTMATTER => .EFRONTMATTER,
        .EINVALIDUTF8 => .EINVALIDUTF8,
        .EINVALIDPATH => .EINVALIDPATH,
        .EUNICODE => .EUNICODE,
    };
}

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    message: []const u8,
    /// Clear remediation guidance for authors/tools.
    remediation: []const u8 = "",
    /// Content-root-relative path, or empty if not applicable.
    source_path: []const u8 = "",
    line: ?u32 = null,
    column: ?u32 = null,
    /// Related entity id, or empty if unknown.
    id: []const u8 = "",

    pub fn isError(self: Diagnostic) bool {
        return self.severity == .error_;
    }
};

/// Sort diagnostics for deterministic JSON (sourcePath, line, column, code, message).
pub fn lessThan(_: void, a: Diagnostic, b: Diagnostic) bool {
    const path_cmp = std.mem.order(u8, a.source_path, b.source_path);
    if (path_cmp != .eq) return path_cmp == .lt;

    const la = a.line orelse std.math.maxInt(u32);
    const lb = b.line orelse std.math.maxInt(u32);
    if (la != lb) return la < lb;

    const ca = a.column orelse std.math.maxInt(u32);
    const cb = b.column orelse std.math.maxInt(u32);
    if (ca != cb) return ca < cb;

    const code_cmp = std.mem.order(u8, a.code.name(), b.code.name());
    if (code_cmp != .eq) return code_cmp == .lt;

    return std.mem.order(u8, a.message, b.message) == .lt;
}

pub fn sortDiagnostics(diags: []Diagnostic) void {
    std.mem.sort(Diagnostic, diags, {}, lessThan);
}

/// Format one diagnostic line for stderr (no trailing newline).
pub fn formatText(d: Diagnostic, allocator: std.mem.Allocator) ![]u8 {
    const rem = if (d.remediation.len > 0)
        try std.fmt.allocPrint(allocator, " [{s}]", .{d.remediation})
    else
        "";
    defer if (d.remediation.len > 0) allocator.free(rem);

    if (d.source_path.len == 0) {
        return std.fmt.allocPrint(allocator, "{s}: {s}: {s}{s}", .{
            d.severity.textName(),
            d.code.name(),
            d.message,
            rem,
        });
    }
    if (d.line) |line| {
        const col = d.column orelse 1;
        return std.fmt.allocPrint(allocator, "{s}: {s}: {s}:{d}:{d}: {s}{s}", .{
            d.severity.textName(),
            d.code.name(),
            d.source_path,
            line,
            col,
            d.message,
            rem,
        });
    }
    return std.fmt.allocPrint(allocator, "{s}: {s}: {s}: {s}{s}", .{
        d.severity.textName(),
        d.code.name(),
        d.source_path,
        d.message,
        rem,
    });
}

pub fn countErrors(diags: []const Diagnostic) usize {
    var n: usize = 0;
    for (diags) |d| {
        if (d.isError()) n += 1;
    }
    return n;
}

/// Thread-safe diagnostic collector for the HTML/preview path. `append` is
/// safe from the bounded parallel renderer (`build --jobs N`); every other
/// phase is single-threaded and takes the same uncontended path. Append
/// failures (OOM) are dropped rather than changing compile behavior, matching
/// the stderr `formatText catch continue` convention.
///
/// The collector owns durable copies of every string field: sources may hand
/// it diagnostics whose strings live on short-lived arenas (e.g. graph
/// validation), and the report is written after the compile call returns.
pub const Collector = struct {
    list: std.ArrayList(Diagnostic) = .empty,
    /// Owns durable copies of diagnostic string fields.
    arena: std.heap.ArenaAllocator,
    mutex: std.Io.Mutex = .init,
    io: std.Io,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) Collector {
        return .{ .arena = std.heap.ArenaAllocator.init(gpa), .io = io };
    }

    pub fn append(self: *Collector, d: Diagnostic) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const a = self.arena.allocator();
        const owned: Diagnostic = .{
            .severity = d.severity,
            .code = d.code,
            .message = a.dupe(u8, d.message) catch return,
            .remediation = a.dupe(u8, d.remediation) catch return,
            .source_path = a.dupe(u8, d.source_path) catch return,
            .line = d.line,
            .column = d.column,
            .id = a.dupe(u8, d.id) catch return,
        };
        self.list.append(self.arena.child_allocator, owned) catch {};
    }

    pub fn deinit(self: *Collector) void {
        self.list.deinit(self.arena.child_allocator);
        self.arena.deinit();
    }
};

test "sortDiagnostics orders by path then line" {
    var diags = [_]Diagnostic{
        .{ .severity = .error_, .code = .EDUPLICATEID, .message = "b", .source_path = "b.md", .line = 1, .column = 1 },
        .{ .severity = .error_, .code = .EDUPLICATEID, .message = "a", .source_path = "a.md", .line = 2, .column = 1 },
        .{ .severity = .error_, .code = .EDUPLICATEID, .message = "a1", .source_path = "a.md", .line = 1, .column = 1 },
    };
    sortDiagnostics(&diags);
    try std.testing.expectEqualStrings("a.md", diags[0].source_path);
    try std.testing.expect(diags[0].line.? == 1);
    try std.testing.expectEqualStrings("a.md", diags[1].source_path);
    try std.testing.expect(diags[1].line.? == 2);
    try std.testing.expectEqualStrings("b.md", diags[2].source_path);
}

test "Code names match contract strings" {
    try std.testing.expectEqualStrings("EDUPLICATEID", Code.EDUPLICATEID.name());
    try std.testing.expectEqualStrings("EPARENTMISSING", Code.EPARENTMISSING.name());
    try std.testing.expectEqualStrings("EPARENTSELF", Code.EPARENTSELF.name());
    try std.testing.expectEqualStrings("EPARENTNOTTRUNK", Code.EPARENTNOTTRUNK.name());
    try std.testing.expectEqualStrings("EPARENTCYCLE", Code.EPARENTCYCLE.name());
    try std.testing.expectEqualStrings("EFRONTMATTER", Code.EFRONTMATTER.name());
    try std.testing.expectEqualStrings("EINVALIDUTF8", Code.EINVALIDUTF8.name());
    try std.testing.expectEqualStrings("EINVALIDPATH", Code.EINVALIDPATH.name());
    try std.testing.expectEqualStrings("ETEXTILE", Code.ETEXTILE.name());
    try std.testing.expectEqualStrings("ECOMPONENT", Code.ECOMPONENT.name());
    try std.testing.expectEqualStrings("EINCLUDESYNTAX", Code.EINCLUDESYNTAX.name());
    try std.testing.expectEqualStrings("EINCLUDEMISSING", Code.EINCLUDEMISSING.name());
    try std.testing.expectEqualStrings("EINCLUDECYCLE", Code.EINCLUDECYCLE.name());
    try std.testing.expectEqualStrings("EREFERENCESYNTAX", Code.EREFERENCESYNTAX.name());
    try std.testing.expectEqualStrings("EREFERENCEMISSING", Code.EREFERENCEMISSING.name());
    try std.testing.expectEqualStrings("EUSAGE", Code.EUSAGE.name());
    try std.testing.expectEqualStrings("EIO", Code.EIO.name());
    try std.testing.expectEqualStrings("EPUBLICATIONLOCATION", Code.EPUBLICATIONLOCATION.name());
}

test "parser categories map to shared diagnostic codes" {
    try std.testing.expectEqual(Code.EFRONTMATTER, parserCategoryToCode(.EFRONTMATTER));
    try std.testing.expectEqual(Code.EINVALIDUTF8, parserCategoryToCode(.EINVALIDUTF8));
    try std.testing.expectEqual(Code.EINVALIDPATH, parserCategoryToCode(.EINVALIDPATH));
}
