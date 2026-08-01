//! Named, deterministic mutations applied after a valid fixture plan exists.
//!
//! A barb is deliberately narrower than a fuzz input. It names one precise
//! mutation and its expected observable behavior, so fixture consumers can
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
    html_missing_local_route,
    html_missing_fragment,
    html_duplicate_id,
    html_unclosed_structure,
    artifact_missing,
    artifact_digest_mismatch,
    search_stale_title,
    deployment_owned_extra,
};

pub const Behavior = enum {
    compile_failure,
    preserved,
    expected_finding,
    no_finding,
};

pub const Phase = enum {
    source,
    theme,
    rendered_html,
    artifact_inventory,
    rendered_search,
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
        .html_missing_local_route,
        .html_missing_fragment,
        .html_duplicate_id,
        .html_unclosed_structure,
        .artifact_missing,
        .artifact_digest_mismatch,
        .search_stale_title,
        => .expected_finding,
        .deployment_owned_extra => .no_finding,
        else => .compile_failure,
    };
}

pub fn phase(kind: Kind) Phase {
    return switch (kind) {
        .invalid_theme => .theme,
        .html_missing_local_route,
        .html_missing_fragment,
        .html_duplicate_id,
        .html_unclosed_structure,
        => .rendered_html,
        .artifact_missing, .artifact_digest_mismatch, .deployment_owned_extra => .artifact_inventory,
        .search_stale_title => .rendered_search,
        else => .source,
    };
}

pub fn expectedFindingCode(kind: Kind) ?[]const u8 {
    return switch (kind) {
        .html_missing_local_route => "HTML_LOCAL_ROUTE_MISSING",
        .html_missing_fragment => "HTML_FRAGMENT_MISSING",
        .html_duplicate_id => "HTML_DUPLICATE_ID",
        .html_unclosed_structure => "HTML_MALFORMED",
        .artifact_missing => "ARTIFACT_MISSING",
        .artifact_digest_mismatch => "ARTIFACT_DIGEST_MISMATCH",
        .search_stale_title => "SEARCH_CONTENT_MISMATCH",
        else => null,
    };
}

pub fn expectedCoverage(kind: Kind) []const u8 {
    return switch (kind) {
        .html_unclosed_structure, .artifact_missing => "incomplete",
        .html_missing_local_route,
        .html_missing_fragment,
        .html_duplicate_id,
        .artifact_digest_mismatch,
        .search_stale_title,
        .deployment_owned_extra,
        => "checked",
        else => "not-applicable",
    };
}

pub fn repair(kind: Kind) []const u8 {
    return switch (kind) {
        .html_missing_local_route => "restore the local href or remove the broken link",
        .html_missing_fragment => "restore the heading id or correct the fragment target",
        .html_duplicate_id => "rename or remove the duplicate rendered id",
        .html_unclosed_structure => "close the rendered element at the mutation site",
        .artifact_missing => "republish or restore the inventoried artifact",
        .artifact_digest_mismatch => "republish the artifact and its receipt",
        .search_stale_title => "regenerate the rendered-search artifact",
        .deployment_owned_extra => "none; leave deployment-owned files outside compiler ownership",
        .unsafe_markdown_link => "none; preserve the literal author link",
        .duplicate_id => "restore the original unique entity id",
        .self_parent => "restore the immediate parent relationship",
        .missing_parent => "restore the existing parent entity id",
        .parent_cycle => "break the parent cycle",
        .unknown_frontmatter => "remove the unsupported frontmatter key",
        .legacy_parent_key => "rename the key to parent or remove it",
        .malformed_frontmatter => "restore valid frontmatter syntax",
        .duplicate_frontmatter_key => "remove the duplicate frontmatter key",
        .broken_wikilink => "restore the target entity or remove the link",
        .missing_include => "restore the include target or remove the include",
        .include_cycle => "break the include cycle",
        .missing_heading_fragment => "restore the heading fragment target",
        .invalid_utf8 => "restore valid UTF-8 bytes",
        .invalid_theme => "restore exactly one required content slot",
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
        .html_missing_local_route => "add one rendered local link to a missing route",
        .html_missing_fragment => "add one rendered link to a missing heading fragment",
        .html_duplicate_id => "emit the same rendered id twice on one page",
        .html_unclosed_structure => "leave one bounded rendered HTML element unclosed",
        .artifact_missing => "delete one published artifact after the baseline receipt",
        .artifact_digest_mismatch => "change one published byte without updating its receipt",
        .search_stale_title => "change one search title without regenerating the index",
        .deployment_owned_extra => "add an unrecorded deployment-owned file",
    };
}

pub fn expectedLabel(kind: Kind) []const u8 {
    return switch (behavior(kind)) {
        .compile_failure => "compile-failure",
        .preserved => "preserved",
        .expected_finding => "expected-finding",
        .no_finding => "no-finding",
    };
}

pub fn isPostPublish(kind: Kind) bool {
    return switch (phase(kind)) {
        .rendered_html, .artifact_inventory, .rendered_search => true,
        else => false,
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
    try std.testing.expectEqual(Phase.rendered_html, phase(.html_duplicate_id));
    try std.testing.expectEqualStrings("HTML_FRAGMENT_MISSING", expectedFindingCode(.html_missing_fragment).?);
    try std.testing.expect(isPostPublish(.artifact_digest_mismatch));
}

test "barb assignment keeps parent mutations off the root when possible" {
    const a = std.testing.allocator;
    const assigned = try assign(a, &.{ .self_parent, .parent_cycle }, 8, 42);
    defer a.free(assigned);
    try std.testing.expectEqual(@as(usize, 2), assigned[0].target);
    try std.testing.expectEqual(@as(usize, 1), assigned[1].target);
    try std.testing.expectEqual(@as(?usize, 5), assigned[1].secondary);
}
