//! Source-level gate: every module is classified, and emitters may not
//! hand-roll their output.
//!
//! `artifact_invariants` proves the *output* is intact for inputs we thought
//! of. This proves the *code* cannot produce output we did not think of.
//!
//! The classification below covers **every** `src/*.zig`, not files matching an
//! emitter naming convention. That distinction is the whole point. Boris's
//! existing machine-facing emitters are `llms.zig`, `context.zig`, `rag.zig`
//! and `search_index.zig` — none of them ends in `_emit.zig`. A developer
//! adding a feed would copy the nearest one and call the file `rss.zig`, and a
//! filename-gated check would wave it straight through. Requiring every file to
//! be classified means a new module of *any* name fails `zig build test` until
//! someone writes down what it is: one line when you add a file, and impossible
//! to forget by choosing a name.

const std = @import("std");

/// Which audited encoder a machine-facing emitter is built on.
const Encoder = enum {
    /// `structured_out.Sink`. Strongest tier: raw byte appends are forbidden
    /// outright, so the only ways into the stream are a comptime literal, an
    /// encoded field, or a justified `rawTrusted`.
    sink,
    /// `json_out`. Raw formatting is forbidden, but this tier cannot prove
    /// every `appendSlice` argument is a literal — JSON structure is assembled
    /// that way. Moving these to the sink would close the gap.
    json_out,
    /// Predates the shared layer and still assembles output by hand. Allowed
    /// only for the modules listed here, each with a written reason, and only
    /// because `emitter_hostile_test.zig` audits their published bytes. A new
    /// emitter may not use this tier: `legacy_budget` below is the ceiling and
    /// raising it is a deliberate, reviewable edit.
    hand_rolled,
};

const Class = union(enum) {
    /// Produces an artifact intended to be read by a machine — a model, an
    /// agent crawler, or the client search runtime.
    emitter: struct { encoder: Encoder, note: []const u8 = "" },
    /// Everything else: parsing, graph work, I/O, HTML assembly for browsers
    /// (covered by its own escaping and by the layout hostile suites), tests,
    /// and the encoding layer itself.
    other,
};

const Module = struct {
    name: []const u8,
    class: Class,
    /// Source text, present only for modules whose encoding is enforced.
    source: ?[]const u8 = null,
    /// Justified `rawTrusted` call sites. Adding one changes this number and
    /// forces a reviewer to look at why.
    raw_trusted_allowed: usize = 0,
};

/// Modules on `hand_rolled` may not grow. This is the ceiling, not a target.
const legacy_budget = 4;

const modules = [_]Module{
    .{
        .name = "rag_emit.zig",
        .class = .{ .emitter = .{ .encoder = .sink } },
        .source = @embedFile("rag_emit.zig"),
        // The page body is the document payload and is emitted verbatim.
        .raw_trusted_allowed = 1,
    },
    .{
        .name = "ir_emit.zig",
        .class = .{ .emitter = .{ .encoder = .json_out } },
        .source = @embedFile("ir_emit.zig"),
    },
    .{
        .name = "search_index.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "client search index; escaping delegates to json_out",
        } },
        .source = @embedFile("search_index.zig"),
    },
    .{
        .name = "artifact_inventory.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "target payload inventory; record values delegate to json_out",
        } },
        .source = @embedFile("artifact_inventory.zig"),
    },
    .{
        .name = "publication_checks.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "target publication evidence; report fields and Doctor findings delegate to json_out",
        } },
        .source = @embedFile("publication_checks.zig"),
    },
    .{
        .name = "publication_claims.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "target claims-and-limitations evidence; report fields and fixed registry text delegate to json_out",
        } },
        .source = @embedFile("publication_claims.zig"),
    },
    .{
        .name = "publication_touches.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "target Touch Atlas evidence; report fields, node metadata, and edge tuples delegate to json_out",
        } },
        .source = @embedFile("publication_touches.zig"),
    },
    .{
        .name = "publication_proof_pack.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "target Proof Pack presentation; model and HTML escaping delegate to json_out plus the local HTML escaper",
        } },
        .source = @embedFile("publication_proof_pack.zig"),
        .raw_trusted_allowed = 0,
    },
    .{
        .name = "sitemap.zig",
        .class = .{ .emitter = .{
            .encoder = .sink,
            .note = "XML Sitemap Protocol output; absolute URLs use the shared strict site URL validator",
        } },
        .source = @embedFile("sitemap.zig"),
        .raw_trusted_allowed = 1,
    },
    .{ .name = "context.zig", .class = .{ .emitter = .{
        .encoder = .hand_rolled,
        .note = "context bundle YAML; audited by emitter_hostile_test, not yet on the sink",
    } } },
    .{ .name = "llms.zig", .class = .{ .emitter = .{
        .encoder = .hand_rolled,
        .note = "llms.txt; flattens newlines and escapes link punctuation inline",
    } } },
    .{ .name = "rag.zig", .class = .{ .emitter = .{
        .encoder = .hand_rolled,
        .note = "RAG orchestration; document bytes come from rag_emit, this writes files",
    } } },
    .{ .name = "package.zig", .class = .{ .emitter = .{
        .encoder = .hand_rolled,
        .note = "review tar of already-emitted IR and RAG artifacts",
    } } },

    .{ .name = "render.zig", .class = .other },
    .{ .name = "artifact_invariants.zig", .class = .other },
    .{ .name = "aside.zig", .class = .other },
    .{ .name = "assemble.zig", .class = .other },
    .{
        .name = "atproto_oauth.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "signed OAuth JWT wire values; runtime claims delegate to json_out",
        } },
        .source = @embedFile("atproto_oauth.zig"),
    },
    .{ .name = "atproto_identity.zig", .class = .other },
    .{ .name = "atproto_handle.zig", .class = .other },
    .{ .name = "atproto_dns.zig", .class = .other },
    .{ .name = "atproto_dns_std.zig", .class = .other },
    .{ .name = "atproto_transport.zig", .class = .other },
    .{ .name = "atproto_transport_std.zig", .class = .other },
    .{ .name = "atproto_authorization.zig", .class = .other },
    .{ .name = "atproto_browser_std.zig", .class = .other },
    .{ .name = "atproto_interactive_std.zig", .class = .other },
    .{ .name = "atproto_loopback_std.zig", .class = .other },
    .{ .name = "cache.zig", .class = .other },
    .{ .name = "cli.zig", .class = .other },
    .{ .name = "compile.zig", .class = .other },
    .{ .name = "content_asset.zig", .class = .other },
    // Cooklang seam, not an emitter: it produces Markdown for the compile
    // pipeline and escapes author text itself, exactly like textile.zig.
    // Parsing is delegated to Oliver; this module renders and validates.
    .{ .name = "cooklang_seam.zig", .class = .other },
    .{ .name = "dependency.zig", .class = .other },
    .{ .name = "diag.zig", .class = .other },
    .{ .name = "diagnostic.zig", .class = .other },
    .{ .name = "doclink.zig", .class = .other },
    .{ .name = "doctor.zig", .class = .other },
    .{ .name = "emitter_discipline_test.zig", .class = .other },
    .{ .name = "emitter_hostile_test.zig", .class = .other },
    .{ .name = "encode.zig", .class = .other },
    .{ .name = "export_scope.zig", .class = .other },
    .{ .name = "fixtures_test.zig", .class = .other },
    .{ .name = "fuzz.zig", .class = .other },
    .{ .name = "graph.zig", .class = .other },
    .{ .name = "github_pages.zig", .class = .other },
    .{ .name = "hardening_test.zig", .class = .other },
    .{ .name = "html_body.zig", .class = .other },
    .{ .name = "html_nav.zig", .class = .other },
    // Emitter: the HTML-path diagnostics report (`--report PATH`). Shares the
    // IR report's json_out discipline and diagnostic-object key order.
    .{ .name = "html_report.zig", .class = .{ .emitter = .{ .encoder = .json_out } }, .source = @embedFile("html_report.zig") },
    .{ .name = "html_relations.zig", .class = .other },
    // Loopback preview server (`watch --serve`): plain HTTP responder, no
    // JSON encoding, no stdout artifact discipline.
    .{ .name = "preview_server.zig", .class = .other },
    .{ .name = "html_scan.zig", .class = .other },
    .{ .name = "html_toc.zig", .class = .other },
    .{ .name = "identity.zig", .class = .other },
    .{ .name = "image_dimensions.zig", .class = .other },
    // Not an emitter: init materializes a deterministic starter tree
    // (content, theme, profile) from fixed constants.
    .{ .name = "init.zig", .class = .other },
    .{ .name = "include.zig", .class = .other },
    .{ .name = "incremental_scale_smoke_test.zig", .class = .other },
    .{ .name = "intelligence.zig", .class = .other },
    .{ .name = "ir_schema_conformance_test.zig", .class = .other },
    .{ .name = "json_out.zig", .class = .other },
    .{ .name = "layout_select.zig", .class = .other },
    .{ .name = "layout_select_hostile_test.zig", .class = .other },
    .{ .name = "link_audit.zig", .class = .other },
    .{ .name = "main.zig", .class = .other },
    .{ .name = "nostr.zig", .class = .other },
    .{
        .name = "nostr_plan.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "offline NIP-23 event intentions; every runtime value goes through json_out",
        } },
        .source = @embedFile("nostr_plan.zig"),
    },
    .{ .name = "page.zig", .class = .other },
    .{ .name = "parser.zig", .class = .other },
    .{ .name = "pathutil.zig", .class = .other },
    .{ .name = "pipeline.zig", .class = .other },
    .{ .name = "publication_profile.zig", .class = .other },
    .{ .name = "publication_location.zig", .class = .other },
    .{ .name = "publication_plan.zig", .class = .{ .emitter = .{ .encoder = .json_out, .note = "canonical normalized publication declaration" } }, .source = @embedFile("publication_plan.zig") },
    .{ .name = "publication_checks_fixture_test.zig", .class = .other },
    .{ .name = "publication_claims_fixture_test.zig", .class = .other },
    .{ .name = "publication_touches_fixture_test.zig", .class = .other },
    .{ .name = "publication_proof_pack_fixture_test.zig", .class = .other },
    .{
        .name = "rss.zig",
        .class = .{ .emitter = .{
            .encoder = .sink,
            .note = "RSS 2.0 XML; site URLs are validated before the reviewed raw URL join",
        } },
        .source = @embedFile("rss.zig"),
        .raw_trusted_allowed = 1,
    },
    .{ .name = "rss_date.zig", .class = .other },
    .{ .name = "route_resolver.zig", .class = .other },
    .{ .name = "scanner.zig", .class = .other },
    .{ .name = "site_url.zig", .class = .other },
    .{ .name = "source_io.zig", .class = .other },
    .{ .name = "structured_out.zig", .class = .other },
    .{ .name = "svg_policy.zig", .class = .other },
    .{ .name = "target.zig", .class = .other },
    .{ .name = "textile.zig", .class = .other },
    .{ .name = "theme.zig", .class = .other },
    .{
        .name = "timings.zig",
        .class = .{ .emitter = .{
            .encoder = .json_out,
            .note = "opt-in --timings phase report; durations/counters delegate to json_out",
        } },
        .source = @embedFile("timings.zig"),
    },
    .{ .name = "unicode_policy.zig", .class = .other },
    .{ .name = "watch.zig", .class = .other },
    .{ .name = "wikilink.zig", .class = .other },
};

/// Formatting calls that write caller-supplied bytes with no encoder between.
const forbidden_everywhere = [_][]const u8{
    ".print(",
    "allocPrint(",
    "std.fmt.format(",
};

/// Raw byte appends. Only the sink tier can ban these, because `json_out`
/// emitters build their structure out of literal fragments.
const forbidden_in_sink_tier = [_][]const u8{
    "appendSlice(",
    "appendNTimes(",
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, needle)) |at| {
        count += 1;
        i = at + needle.len;
    }
    return count;
}

fn rejectPatterns(name: []const u8, source: []const u8, patterns: []const []const u8) !void {
    for (patterns) |pattern| {
        const found = countOccurrences(source, pattern);
        if (found != 0) {
            std.debug.print(
                \\
                \\{s} contains {d} use(s) of `{s}`.
                \\Emitters must write through an audited encoder so page-controlled
                \\values are escaped for the container they land in. With
                \\structured_out.Sink: lit() for template text, field()/fieldJoined()
                \\for runtime values, rawTrusted() with a written justification when
                \\the bytes really are safe.
                \\
            , .{ name, found, pattern });
            return error.EmitterBypassesEncoder;
        }
    }
}

test "enforced emitters write only through an audited encoder" {
    for (modules) |module| {
        const spec = switch (module.class) {
            .emitter => |e| e,
            .other => continue,
        };
        const source = module.source orelse {
            // Only the hand_rolled tier may omit its source; everything else
            // must be checkable, and a hand-rolled entry must say why.
            try std.testing.expectEqual(Encoder.hand_rolled, spec.encoder);
            try std.testing.expect(spec.note.len > 0);
            continue;
        };
        try rejectPatterns(module.name, source, &forbidden_everywhere);
        switch (spec.encoder) {
            .sink => {
                try rejectPatterns(module.name, source, &forbidden_in_sink_tier);
                try std.testing.expect(std.mem.indexOf(u8, source, "structured_out") != null);
            },
            .json_out => try std.testing.expect(std.mem.indexOf(u8, source, "json_out.") != null),
            .hand_rolled => {},
        }
    }
}

test "the hand-rolled emitter tier does not grow" {
    var legacy: usize = 0;
    for (modules) |module| switch (module.class) {
        .emitter => |e| if (e.encoder == .hand_rolled) {
            legacy += 1;
        },
        .other => {},
    };
    if (legacy > legacy_budget) {
        std.debug.print(
            \\
            \\{d} modules are on the hand_rolled tier; the budget is {d}.
            \\A new emitter must use structured_out.Sink. If an existing module
            \\genuinely cannot move yet, raise the budget in this file and say
            \\why in the commit — do not add silently.
            \\
        , .{ legacy, legacy_budget });
        return error.HandRolledTierGrew;
    }
}

test "rawTrusted opt-outs stay at their reviewed count" {
    for (modules) |module| {
        const source = module.source orelse continue;
        const found = countOccurrences(source, "rawTrusted(");
        if (found != module.raw_trusted_allowed) {
            std.debug.print(
                \\
                \\{s} has {d} rawTrusted call(s); {d} are recorded as reviewed.
                \\Each one is an unescaped runtime write. If the new one is correct,
                \\update raw_trusted_allowed in this test and say why in the commit.
                \\
            , .{ module.name, found, module.raw_trusted_allowed });
            return error.UnreviewedRawTrusted;
        }
    }
}

test "every source module is classified" {
    // Not "every module matching a naming convention" — every module. A file
    // called rss.zig is caught here on the first `zig build test`, which is
    // exactly the case a filename-gated check misses. Test cwd is the package
    // root.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);

    var unclassified: std.ArrayList([]u8) = .empty;
    defer {
        for (unclassified.items) |m| gpa.free(m);
        unclassified.deinit(gpa);
    }
    var seen: usize = 0;

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        seen += 1;
        var classified = false;
        for (modules) |module| {
            if (std.mem.eql(u8, module.name, entry.name)) classified = true;
        }
        if (!classified) try unclassified.append(gpa, try gpa.dupe(u8, entry.name));
    }

    if (unclassified.items.len > 0) {
        std.debug.print(
            \\
            \\These source modules are not classified in this file:
            \\
        , .{});
        for (unclassified.items) |name| std.debug.print("  src/{s}\n", .{name});
        std.debug.print(
            \\Add each one as `.other`, or — if it writes an artifact meant to be
            \\read by a model, an agent crawler or the search runtime — as an
            \\emitter with the encoder it is built on. Naming the file something
            \\other than *_emit.zig does not exempt it.
            \\
        , .{});
        return error.UnclassifiedModule;
    }

    // A deleted module leaves a stale row, and a rename that emptied the scan
    // would otherwise pass silently.
    try std.testing.expectEqual(modules.len, seen);
}

test "the sink itself still refuses runtime literals" {
    // `lit` takes a comptime parameter. If that ever relaxes to a runtime
    // slice, the compile-time guarantee is gone and every emitter silently
    // loses its safety net, so pin the signature.
    const source = @embedFile("structured_out.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn lit(self: *Sink, comptime s: []const u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn rawTrusted(self: *Sink, comptime why: []const u8") != null);
}
