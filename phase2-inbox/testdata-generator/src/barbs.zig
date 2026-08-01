//! Named, deterministic mutations applied after a valid fixture plan exists.
//!
//! A barb is deliberately narrower than a fuzz input. It names one precise
//! mutation and its expected observable behavior, so benchmark consumers can
//! compare a compiler's response without reverse-engineering random bytes.

const std = @import("std");

pub const Kind = enum {
    duplicate_id,
    self_parent,
    missing_parent,
    parent_cycle,
    unknown_frontmatter,
    legacy_parent_key,
    malformed_frontmatter,
    duplicate_frontmatter_key,
    broken_wikilink,
    missing_include,
    include_cycle,
    missing_heading_fragment,
    unsafe_markdown_link,
    invalid_utf8,
    invalid_theme,
};

pub const Behavior = enum {
    compile_failure,
    preserved,
};

pub const Assignment = struct {
    kind: Kind,
    target: usize,
    secondary: ?usize = null,
};

pub fn parse(text: []const u8) !Kind {
    inline for (std.meta.fields(Kind)) |field| {
        if (std.mem.eql(u8, text, field.name)) return @field(Kind, field.name);
    }
    return error.UnknownBarb;
}

pub fn name(kind: Kind) []const u8 {
    return @tagName(kind);
}

pub fn behavior(kind: Kind) Behavior {
    return switch (kind) {
        .unsafe_markdown_link => .preserved,
        else => .compile_failure,
    };
}

pub fn description(kind: Kind) []const u8 {
    return switch (kind) {
        .duplicate_id => "override one page id with another page's id",
        .self_parent => "make a Satellite point at itself",
        .missing_parent => "point parent at an absent entity id",
        .parent_cycle => "close a two-page parent cycle",
        .unknown_frontmatter => "add a closed-grammar frontmatter key",
        .legacy_parent_key => "use the forbidden legacy parentEntry key",
        .malformed_frontmatter => "break the frontmatter field grammar",
        .duplicate_frontmatter_key => "repeat one recognized frontmatter key",
        .broken_wikilink => "reference a missing wiki-link entity",
        .missing_include => "reference a missing include fragment",
        .include_cycle => "make two include fragments recurse",
        .missing_heading_fragment => "reference a missing heading fragment",
        .unsafe_markdown_link => "exercise a traversal link that must stay literal",
        .invalid_utf8 => "append an invalid UTF-8 byte to a page",
        .invalid_theme => "remove the required content slot from the theme",
    };
}

pub fn expectedLabel(kind: Kind) []const u8 {
    return switch (behavior(kind)) {
        .compile_failure => "compile-failure",
        .preserved => "preserved",
    };
}

pub fn assign(
    allocator: std.mem.Allocator,
    kinds: []const Kind,
    page_count: usize,
    seed: u64,
) ![]Assignment {
    var out: std.ArrayList(Assignment) = .empty;
    try out.ensureTotalCapacity(allocator, kinds.len);

    for (kinds, 0..) |kind, ordinal| {
        if (page_count == 0) return error.InvalidPageCount;
        var target = @as(usize, @intCast(mix(seed, ordinal + 1) % page_count));

        // Keep graph mutations on pages whose topology makes the mutation
        // meaningful. Page 0 is the root trunk; page 1 is a guide trunk when
        // it exists; page 2 is normally a Satellite.
        switch (kind) {
            .self_parent => {
                if (page_count > 2) {
                    target = 2;
                } else if (page_count > 1) {
                    target = 1;
                }
            },
            .missing_parent => {
                if (page_count > 3) {
                    target = 3;
                } else if (page_count > 1) {
                    target = 1;
                }
            },
            .legacy_parent_key => {
                if (page_count > 4) {
                    target = 4;
                } else if (page_count > 1) {
                    target = 1;
                }
            },
            .parent_cycle => {
                if (page_count > 3) {
                    target = 1;
                } else if (page_count > 2) {
                    target = 2;
                } else if (page_count > 1) {
                    target = 1;
                }
            },
            else => {},
        }

        var secondary: ?usize = null;
        if (kind == .parent_cycle) {
            secondary = if (page_count > 5) 5 else if (target + 1 < page_count) target + 1 else 0;
            if (secondary.? == target) secondary = null;
        }

        try out.append(allocator, .{
            .kind = kind,
            .target = target,
            .secondary = secondary,
        });
    }
    return out.toOwnedSlice(allocator);
}

pub fn mix(seed: u64, value: u64) u64 {
    var z = seed ^ (value +% 0x9e3779b97f4a7c15);
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    return z ^ (z >> 31);
}

test "barb names round-trip and preserved behavior is explicit" {
    try std.testing.expectEqual(Kind.duplicate_id, try parse("duplicate_id"));
    try std.testing.expectEqual(Behavior.preserved, behavior(.unsafe_markdown_link));
    try std.testing.expectEqual(Behavior.compile_failure, behavior(.invalid_utf8));
}

test "barb assignment keeps parent mutations off the root when possible" {
    const a = std.testing.allocator;
    const assigned = try assign(a, &.{ .self_parent, .parent_cycle }, 8, 42);
    defer a.free(assigned);
    try std.testing.expectEqual(@as(usize, 2), assigned[0].target);
    try std.testing.expectEqual(@as(usize, 1), assigned[1].target);
    try std.testing.expectEqual(@as(?usize, 5), assigned[1].secondary);
}
