//! Deterministic renderer for the normalized publication-plan declaration.
//!
//! The renderer accepts only an owned-semantic `PublicationPlan` view. It does
//! not parse profile JSON, read the workspace, inspect content, or publish any
//! projection. JSON structure is fixed here and runtime values go through the
//! repository's shared `json_out` encoder.

const std = @import("std");
const json_out = @import("json_out.zig");
const publication_profile = @import("publication_profile.zig");

pub const artifact_format = "boris-publication-plan";
pub const schema_version: u32 = 1;

/// Render one normalized publication declaration as canonical UTF-8 JSON.
///
/// The returned bytes are allocator-owned and always end in one LF. The
/// borrowed plan is never mutated and workspace/execution state is not
/// reachable from the serialization surface.
pub fn render(gpa: std.mem.Allocator, plan: *const publication_profile.PublicationPlan) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    try out.appendSlice(gpa, "{\n  \"format\": ");
    try json_out.writeString(&out, gpa, artifact_format);
    try out.appendSlice(gpa, ",\n  \"schema_version\": ");
    try json_out.writeUsize(&out, gpa, schema_version);
    try out.appendSlice(gpa, ",\n  \"input\": ");
    try json_out.writeString(&out, gpa, plan.input);
    try out.appendSlice(gpa, ",\n  \"input_format\": ");
    try json_out.writeString(&out, gpa, inputFormatName(plan.input_format));
    try out.appendSlice(gpa, ",\n  \"site\": ");
    if (plan.site) |site| {
        try renderSite(&out, gpa, site);
    } else {
        try json_out.writeNull(&out, gpa);
    }
    try out.appendSlice(gpa, ",\n  \"targets\": [");
    for (plan.targets, 0..) |target, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n    ");
        try renderTarget(&out, gpa, target);
    }
    if (plan.targets.len > 0) try out.appendSlice(gpa, "\n  ");
    try out.appendSlice(gpa, "],\n  \"editions\": ");
    try renderEditions(&out, gpa, plan);
    try out.appendSlice(gpa, "\n}\n");
    return out.toOwnedSlice(gpa);
}

fn inputFormatName(input_format: publication_profile.InputFormat) []const u8 {
    return switch (input_format) {
        .markdown => "markdown",
        .textile => "textile",
    };
}

fn renderSite(out: *std.ArrayList(u8), gpa: std.mem.Allocator, site: publication_profile.SiteMetadata) !void {
    try out.appendSlice(gpa, "{\n    \"url\": ");
    try writeOptionalString(out, gpa, site.url);
    try out.appendSlice(gpa, ",\n    \"title\": ");
    try writeOptionalString(out, gpa, site.title);
    try out.appendSlice(gpa, ",\n    \"description\": ");
    try writeOptionalString(out, gpa, site.description);
    try out.appendSlice(gpa, "\n  }");
}

fn writeOptionalString(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: ?[]const u8) !void {
    if (value) |v| {
        try json_out.writeString(out, gpa, v);
    } else {
        try json_out.writeNull(out, gpa);
    }
}

fn renderTarget(out: *std.ArrayList(u8), gpa: std.mem.Allocator, target: publication_profile.HtmlTargetPlan) !void {
    try out.appendSlice(gpa, "{\n      \"name\": ");
    try json_out.writeString(out, gpa, target.name);
    try out.appendSlice(gpa, ",\n      \"output\": ");
    try json_out.writeString(out, gpa, target.output);
    try out.appendSlice(gpa, ",\n      \"public\": ");
    try json_out.writeBool(out, gpa, target.public);
    try out.appendSlice(gpa, ",\n      \"theme\": ");
    writeOptionalString(out, gpa, target.theme) catch |err| return err;
    try out.appendSlice(gpa, ",\n      \"layout\": ");
    try writeOptionalString(out, gpa, target.layout);
    try out.appendSlice(gpa, ",\n      \"layout_rules\": [");
    for (target.layout_rules, 0..) |rule, i| {
        if (i > 0) try out.appendSlice(gpa, ",");
        try out.appendSlice(gpa, "\n        {\"selector\": ");
        try writeSelector(out, gpa, rule);
        try out.appendSlice(gpa, ", \"layout\": ");
        try json_out.writeString(out, gpa, rule.layout_path);
        try out.appendSlice(gpa, "}");
    }
    if (target.layout_rules.len > 0) try out.appendSlice(gpa, "\n      ");
    try out.appendSlice(gpa, "],\n      \"projections\": ");
    try renderProjections(out, gpa, target);
    try out.appendSlice(gpa, "\n    }");
}

fn writeSelector(out: *std.ArrayList(u8), gpa: std.mem.Allocator, rule: anytype) !void {
    try out.append(gpa, '"');
    try out.appendSlice(gpa, switch (rule.kind) {
        .id => "id:",
        .glob => "glob:",
        .role => "role:",
    });
    try json_out.escapeAppend(out, gpa, rule.value);
    try out.append(gpa, '"');
}

fn renderProjections(out: *std.ArrayList(u8), gpa: std.mem.Allocator, target: publication_profile.HtmlTargetPlan) !void {
    try out.appendSlice(gpa, "{\n        \"html\": true,\n        \"sitemap\": ");
    if (target.sitemap) |sitemap| {
        try out.appendSlice(gpa, "{\"path\": ");
        try json_out.writeString(out, gpa, sitemap.path);
        try out.appendSlice(gpa, "}");
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, ",\n        \"rss\": ");
    if (target.rss) |rss| {
        try out.appendSlice(gpa, "{\"path\": ");
        try json_out.writeString(out, gpa, rss.path);
        try out.appendSlice(gpa, ", \"limit\": ");
        try json_out.writeUsize(out, gpa, rss.limit);
        try out.appendSlice(gpa, "}");
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, ",\n        \"llms\": ");
    if (target.llms) |llms| {
        try out.appendSlice(gpa, "{\"path\": ");
        try json_out.writeString(out, gpa, llms.path);
        try out.appendSlice(gpa, "}");
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, "\n      }");
}

fn renderEditions(out: *std.ArrayList(u8), gpa: std.mem.Allocator, plan: *const publication_profile.PublicationPlan) !void {
    try out.appendSlice(gpa, "{\n    \"ir\": ");
    if (plan.ir) |ir| {
        try out.appendSlice(gpa, "{\"output\": ");
        try json_out.writeString(out, gpa, ir.output);
        try out.appendSlice(gpa, "}");
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, ",\n    \"rag\": ");
    if (plan.rag) |rag| {
        try out.appendSlice(gpa, "{\"output\": ");
        try json_out.writeString(out, gpa, rag.output);
        try out.appendSlice(gpa, ", \"scope\": ");
        try writeOptionalString(out, gpa, rag.scope);
        try out.appendSlice(gpa, ", \"split_size\": ");
        try writeOptionalUsize(out, gpa, rag.split_size);
        try out.appendSlice(gpa, ", \"bundles_only\": ");
        try json_out.writeBool(out, gpa, rag.bundles_only);
        try out.appendSlice(gpa, "}");
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, ",\n    \"context\": ");
    if (plan.context) |context| {
        try out.appendSlice(gpa, "{\"output\": ");
        try json_out.writeString(out, gpa, context.output);
        try out.appendSlice(gpa, ", \"scope\": ");
        try writeOptionalString(out, gpa, context.scope);
        try out.appendSlice(gpa, ", \"split_size\": ");
        try writeOptionalUsize(out, gpa, context.split_size);
        try out.appendSlice(gpa, "}");
    } else {
        try json_out.writeNull(out, gpa);
    }
    try out.appendSlice(gpa, "\n  }");
}

fn writeOptionalUsize(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: ?usize) !void {
    if (value) |v| {
        try json_out.writeUsize(out, gpa, v);
    } else {
        try json_out.writeNull(out, gpa);
    }
}

// --- focused renderer and schema tests ------------------------------------

fn readFixture(path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, std.testing.allocator, .limited(1024 * 1024));
}

fn parseProfile(source: []const u8, overrides: publication_profile.ProfileOverrides) !publication_profile.PublicationRequest {
    return publication_profile.parseBytes(
        std.testing.allocator,
        .{ .root = try std.testing.allocator.dupe(u8, "/private/boris/publication-plan-fixture") },
        source,
        overrides,
    );
}

fn renderFixture(profile_path: []const u8, expected_path: []const u8) !void {
    const source = try readFixture(profile_path);
    defer std.testing.allocator.free(source);
    const expected = try readFixture(expected_path);
    defer std.testing.allocator.free(expected);

    var request = try parseProfile(source, .{});
    defer request.deinit(std.testing.allocator);
    const actual = try render(std.testing.allocator, &request.plan);
    defer std.testing.allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
}

test "minimal publication plan matches the exact golden bytes" {
    try renderFixture(
        "docs/contracts/fixtures/publication-plan/minimal/profile.json",
        "docs/contracts/fixtures/publication-plan/minimal/expected/plan.json",
    );
}

test "full publication plan matches the exact golden bytes" {
    try renderFixture(
        "docs/contracts/fixtures/publication-plan/full/profile.json",
        "docs/contracts/fixtures/publication-plan/full/expected/plan.json",
    );
}

test "repeated rendering is byte-identical and does not expose workspace state" {
    const source = try readFixture("docs/contracts/fixtures/publication-plan/full/profile.json");
    defer std.testing.allocator.free(source);
    var request = try parseProfile(source, .{});
    defer request.deinit(std.testing.allocator);

    const first = try render(std.testing.allocator, &request.plan);
    defer std.testing.allocator.free(first);
    const second = try render(std.testing.allocator, &request.plan);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "/private/boris/publication-plan-fixture") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "jobs") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "quiet") == null);
    try std.testing.expect(std.mem.indexOf(u8, first, "incremental") == null);
}

test "profile key ordering does not affect canonical plan bytes" {
    const first_source =
        "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"targets\":[{\"name\":\"z\",\"output\":\"z-out\",\"layout\":\"layouts/z.html\"},{\"name\":\"a\",\"output\":\"a-out\",\"layout\":\"layouts/a.html\"}]}";
    const second_source =
        "{\"targets\":[{\"layout\":\"layouts/a.html\",\"output\":\"a-out\",\"name\":\"a\"},{\"output\":\"z-out\",\"name\":\"z\",\"layout\":\"layouts/z.html\"}],\"schema_version\":1,\"format\":\"boris-publication-profile\"}";
    var first_request = try parseProfile(first_source, .{});
    defer first_request.deinit(std.testing.allocator);
    var second_request = try parseProfile(second_source, .{});
    defer second_request.deinit(std.testing.allocator);
    const first = try render(std.testing.allocator, &first_request.plan);
    defer std.testing.allocator.free(first);
    const second = try render(std.testing.allocator, &second_request.plan);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualStrings(first, second);
    try std.testing.expectEqualStrings("a", first_request.plan.targets[0].name);
    try std.testing.expectEqualStrings("z", first_request.plan.targets[1].name);
}

test "publication-affecting overrides enter the plan while execution stays out" {
    const source =
        "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"targets\":[{\"name\":\"public\",\"output\":\"dist\",\"layout\":\"layouts/main.html\"}]}";
    var request = try parseProfile(source, .{
        .input = "docs",
        .input_format = .textile,
        .html_output = "preview",
        .jobs = 4,
        .incremental = true,
        .quiet = true,
    });
    defer request.deinit(std.testing.allocator);
    const bytes = try render(std.testing.allocator, &request.plan);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"input\": \"docs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"input_format\": \"textile\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "\"output\": \"preview\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "jobs") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "quiet") == null);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "incremental") == null);
    try std.testing.expectEqual(@as(usize, 4), request.execution.jobs);
    try std.testing.expect(request.execution.incremental);
    try std.testing.expect(request.execution.quiet);
}

test "strict profile failures stop before a publication plan can be rendered" {
    const duplicate =
        "{\"format\":\"boris-publication-profile\",\"format\":\"boris-publication-profile\",\"schema_version\":1,\"targets\":[{\"name\":\"public\",\"output\":\"dist\",\"layout\":\"layouts/main.html\"}]}";
    const unknown =
        "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"unexpected\":true,\"targets\":[{\"name\":\"public\",\"output\":\"dist\",\"layout\":\"layouts/main.html\"}]}";
    try std.testing.expectError(error.DuplicateKey, parseProfile(duplicate, .{}));
    try std.testing.expectError(error.UnknownKey, parseProfile(unknown, .{}));
}

test "public projection metadata remains fail-closed before rendering" {
    const non_public =
        "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"targets\":[{\"name\":\"private\",\"output\":\"dist\",\"layout\":\"layouts/main.html\",\"sitemap\":{\"path\":\"sitemap.xml\"}}]}";
    const missing_site =
        "{\"format\":\"boris-publication-profile\",\"schema_version\":1,\"targets\":[{\"name\":\"public\",\"output\":\"dist\",\"public\":true,\"rss\":{\"path\":\"feed.xml\"}}]}";
    try std.testing.expectError(error.PublicArtifactRequiresPublicTarget, parseProfile(non_public, .{}));
    try std.testing.expectError(error.PublicArtifactRequiresSiteUrl, parseProfile(missing_site, .{}));
}

test "rendered plan parses and conforms to its published schema" {
    const source = try readFixture("docs/contracts/fixtures/publication-plan/full/profile.json");
    defer std.testing.allocator.free(source);
    const schema_bytes = try readFixture("docs/contracts/schemas/publication-plan-1.schema.json");
    defer std.testing.allocator.free(schema_bytes);
    var request = try parseProfile(source, .{});
    defer request.deinit(std.testing.allocator);
    const plan_bytes = try render(std.testing.allocator, &request.plan);
    defer std.testing.allocator.free(plan_bytes);

    var schema = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, schema_bytes, .{});
    defer schema.deinit();
    var document = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, plan_bytes, .{});
    defer document.deinit();
    const validator: SchemaValidator = .{ .root = schema.value };
    try validator.validate(schema.value, document.value);
}

const SchemaError = error{ SchemaViolation, UnsupportedRef, MissingDefs, MissingDef, UnsupportedSchema };

const SchemaValidator = struct {
    root: std.json.Value,

    fn resolve(self: @This(), schema: std.json.Value) SchemaError!std.json.Value {
        const ref = schema.object.get("$ref") orelse return schema;
        if (ref != .string or !std.mem.startsWith(u8, ref.string, "#/$defs/")) return error.UnsupportedRef;
        const defs = self.root.object.get("$defs") orelse return error.MissingDefs;
        return defs.object.get(ref.string["#/$defs/".len..]) orelse error.MissingDef;
    }

    fn typeMatches(name: []const u8, value: std.json.Value) bool {
        if (std.mem.eql(u8, name, "object")) return value == .object;
        if (std.mem.eql(u8, name, "array")) return value == .array;
        if (std.mem.eql(u8, name, "string")) return value == .string;
        if (std.mem.eql(u8, name, "boolean")) return value == .bool;
        if (std.mem.eql(u8, name, "null")) return value == .null;
        if (std.mem.eql(u8, name, "integer")) return value == .integer;
        return false;
    }

    fn scalarEqual(a: std.json.Value, b: std.json.Value) bool {
        return switch (a) {
            .null => b == .null,
            .bool => b == .bool and a.bool == b.bool,
            .integer => b == .integer and a.integer == b.integer,
            .string => b == .string and std.mem.eql(u8, a.string, b.string),
            else => false,
        };
    }

    fn validateType(_: @This(), type_value: std.json.Value, document: std.json.Value) SchemaError!void {
        const matches = switch (type_value) {
            .string => typeMatches(type_value.string, document),
            .array => blk: {
                for (type_value.array.items) |entry| {
                    if (entry == .string and typeMatches(entry.string, document)) break :blk true;
                }
                break :blk false;
            },
            else => return error.UnsupportedSchema,
        };
        if (!matches) return error.SchemaViolation;
    }

    fn validate(self: @This(), schema_in: std.json.Value, document: std.json.Value) SchemaError!void {
        const schema = try self.resolve(schema_in);
        if (schema.object.get("const")) |constant| {
            if (!scalarEqual(constant, document)) return error.SchemaViolation;
        }
        if (schema.object.get("enum")) |values| {
            var matched = false;
            for (values.array.items) |candidate| {
                if (scalarEqual(candidate, document)) {
                    matched = true;
                    break;
                }
            }
            if (!matched) return error.SchemaViolation;
        }
        if (schema.object.get("type")) |type_value| try self.validateType(type_value, document);

        if (schema.object.get("properties")) |properties| {
            if (document == .null) return;
            if (document != .object) return error.SchemaViolation;
            if (schema.object.get("required")) |required| {
                for (required.array.items) |name| {
                    if (document.object.get(name.string) == null) return error.SchemaViolation;
                }
            }
            if (schema.object.get("additionalProperties")) |additional| {
                if (additional == .bool and !additional.bool) {
                    var iterator = document.object.iterator();
                    while (iterator.next()) |entry| {
                        if (properties.object.get(entry.key_ptr.*) == null) return error.SchemaViolation;
                    }
                }
            }
            var iterator = document.object.iterator();
            while (iterator.next()) |entry| {
                if (properties.object.get(entry.key_ptr.*)) |property_schema| {
                    try self.validate(property_schema, entry.value_ptr.*);
                }
            }
        }
        if (schema.object.get("items")) |items| {
            if (document != .array) return error.SchemaViolation;
            for (document.array.items) |entry| try self.validate(items, entry);
        }
    }
};
