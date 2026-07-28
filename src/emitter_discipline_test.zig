//! Source-level gate: registered emitters may not hand-roll their output.
//!
//! `artifact_invariants` proves the *output* is intact for inputs we thought
//! of. This proves the *code* cannot produce output we did not think of, by
//! forbidding raw formatting in the modules that assemble artifacts. Together
//! they are why a fifth emitter — an RSS feed, say — cannot quietly reintroduce
//! the class of bug this branch fixes: either it writes through an audited
//! encoder, or this test fails.
//!
//! The other half of the trap is `test "every emitter module is registered"`:
//! it enumerates `src/` at test time, so a new `src/*_emit.zig` fails on the
//! first `zig build test` without anyone remembering to wire it up.
//! `scripts/emitter-discipline.sh` reports the same thing for humans running
//! the release gate; the authority is this file, which needs no shell.

const std = @import("std");

/// Which audited encoder an emitter is built on.
const Encoder = enum {
    /// `structured_out.Sink`. Strongest tier: raw byte appends are forbidden
    /// outright, so the only ways into the stream are a comptime literal, an
    /// encoded field, or a justified `rawTrusted`.
    sink,
    /// `json_out`. Raw formatting is still forbidden, but this tier cannot
    /// prove every `appendSlice` argument is a literal — the JSON structure is
    /// assembled that way. Moving these to the sink would close that gap.
    json_out,
};

const Emitter = struct {
    name: []const u8,
    source: []const u8,
    encoder: Encoder,
    /// Justified `rawTrusted` call sites. Adding one changes this number and
    /// forces a reviewer to look at why.
    raw_trusted_allowed: usize = 0,
};

const registry = [_]Emitter{
    .{
        .name = "rag_emit.zig",
        .source = @embedFile("rag_emit.zig"),
        .encoder = .sink,
        // The page body is the document payload and is emitted verbatim.
        .raw_trusted_allowed = 1,
    },
    .{
        .name = "ir_emit.zig",
        .source = @embedFile("ir_emit.zig"),
        .encoder = .json_out,
    },
};

/// Formatting calls that write caller-supplied bytes with no encoder in between.
const forbidden_everywhere = [_][]const u8{
    ".print(",
    "allocPrint(",
    "bufPrint(",
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

fn rejectPatterns(emitter: Emitter, patterns: []const []const u8) !void {
    for (patterns) |pattern| {
        const found = countOccurrences(emitter.source, pattern);
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
            , .{ emitter.name, found, pattern });
            return error.EmitterBypassesEncoder;
        }
    }
}

test "registered emitters write only through an audited encoder" {
    for (registry) |emitter| {
        try rejectPatterns(emitter, &forbidden_everywhere);
        switch (emitter.encoder) {
            .sink => {
                try rejectPatterns(emitter, &forbidden_in_sink_tier);
                try std.testing.expect(std.mem.indexOf(u8, emitter.source, "structured_out") != null);
            },
            .json_out => {
                try std.testing.expect(std.mem.indexOf(u8, emitter.source, "json_out.") != null);
            },
        }
    }
}

test "rawTrusted opt-outs stay at their reviewed count" {
    for (registry) |emitter| {
        const found = countOccurrences(emitter.source, "rawTrusted(");
        if (found != emitter.raw_trusted_allowed) {
            std.debug.print(
                \\
                \\{s} has {d} rawTrusted call(s); {d} are recorded as reviewed.
                \\Each one is an unescaped runtime write. If the new one is correct,
                \\update raw_trusted_allowed in this test and say why in the commit.
                \\
            , .{ emitter.name, found, emitter.raw_trusted_allowed });
            return error.UnreviewedRawTrusted;
        }
    }
}

test "every emitter module is registered" {
    // The other half of the trap: an emitter that is never added to `registry`
    // inherits none of the checks above. Enumerating the directory means a new
    // `src/*_emit.zig` fails here on the first `zig build test`, with no shell
    // script or CI wiring to remember. Test cwd is the package root.
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var dir = try std.Io.Dir.cwd().openDir(io, "src", .{ .iterate = true });
    defer dir.close(io);

    var missing: std.ArrayList([]u8) = .empty;
    defer {
        for (missing.items) |m| gpa.free(m);
        missing.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, "_emit.zig")) continue;
        var registered = false;
        for (registry) |emitter| {
            if (std.mem.eql(u8, emitter.name, entry.name)) registered = true;
        }
        if (!registered) try missing.append(gpa, try gpa.dupe(u8, entry.name));
    }

    if (missing.items.len > 0) {
        std.debug.print(
            \\
            \\These emitter modules are not in the registry in this file:
            \\
        , .{});
        for (missing.items) |name| std.debug.print("  src/{s}\n", .{name});
        std.debug.print(
            \\Add each one with the encoder it is built on, so its output
            \\encoding is enforced rather than assumed.
            \\
        , .{});
        return error.UnregisteredEmitter;
    }
    // Guard against a rename of the convention silently emptying this check.
    try std.testing.expect(registry.len >= 2);
}

test "the sink itself still refuses runtime literals" {
    // `lit` takes a comptime parameter. If that ever relaxes to a runtime
    // slice, the compile-time guarantee is gone and every emitter silently
    // loses its safety net, so pin the signature.
    const source = @embedFile("structured_out.zig");
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn lit(self: *Sink, comptime s: []const u8)") != null);
    try std.testing.expect(std.mem.indexOf(u8, source, "pub fn rawTrusted(self: *Sink, comptime why: []const u8") != null);
}
