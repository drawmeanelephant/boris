//! IR ↔ JSON Schema conformance.
//!
//! `docs/contracts/schemas/*.schema.json` are published so IR consumers do not
//! have to hand-roll parsers from prose. A published schema that has drifted
//! from the emitter is worse than no schema at all, so this test validates
//! freshly emitted IR against each one and fails on drift in **either**
//! direction: a required property the emitter stopped writing, or a property
//! the emitter started writing that the schema does not describe.
//!
//! The prose contract in `docs/contracts/ir-schema.md` stays normative. This is
//! a mechanical check that the machine-readable twin still tells the truth.
//!
//! Disposable artifacts under `test-output/` (gitignored).

const std = @import("std");
const Io = std.Io;
const pipeline = @import("pipeline.zig");
const parser = @import("parser.zig");
const recipe_scale = @import("recipe_scale.zig");
const recipe_scale_view = @import("recipe_scale_view.zig");

const output_root = "test-output";
const work_dir = output_root ++ "/ir-schema-conformance";

/// Minimal validator for the JSON Schema subset the IR schemas use:
/// `$ref` (local `#/$defs/*`), `type`, `const`, `enum`, `required`,
/// `properties`, `additionalProperties: false`, `items`, and the
/// `minLength` / `maxLength` / `minItems` / `maxItems` bounds.
const Validator = struct {
    fn codepointLen(s: []const u8) usize {
        return std.unicode.utf8CountCodepoints(s) catch s.len;
    }

    root: std.json.Value,
    arena: std.mem.Allocator,
    /// Real conformance runs report the offending path; the self-check below
    /// expects violations, so it stays quiet to keep gate output clean.
    verbose: bool = true,

    fn resolve(self: Validator, schema: std.json.Value) !std.json.Value {
        const ref_v = schema.object.get("$ref") orelse return schema;
        const prefix = "#/$defs/";
        if (!std.mem.startsWith(u8, ref_v.string, prefix)) return error.UnsupportedRef;
        const defs = self.root.object.get("$defs") orelse return error.MissingDefs;
        return defs.object.get(ref_v.string[prefix.len..]) orelse error.MissingDef;
    }

    fn typeMatches(name: []const u8, v: std.json.Value) bool {
        if (std.mem.eql(u8, name, "object")) return v == .object;
        if (std.mem.eql(u8, name, "array")) return v == .array;
        if (std.mem.eql(u8, name, "string")) return v == .string;
        if (std.mem.eql(u8, name, "boolean")) return v == .bool;
        if (std.mem.eql(u8, name, "null")) return v == .null;
        if (std.mem.eql(u8, name, "integer")) return v == .integer;
        if (std.mem.eql(u8, name, "number")) return v == .integer or v == .float;
        return false;
    }

    fn scalarEql(a: std.json.Value, b: std.json.Value) bool {
        return switch (a) {
            .null => b == .null,
            .bool => b == .bool and a.bool == b.bool,
            .integer => b == .integer and a.integer == b.integer,
            .string => b == .string and std.mem.eql(u8, a.string, b.string),
            else => false,
        };
    }

    fn fail(self: Validator, path: []const u8, comptime what: []const u8, detail: []const u8) error{SchemaViolation} {
        if (self.verbose) {
            std.debug.print("\nIR schema conformance: {s} at `{s}`: {s}\n", .{ what, path, detail });
        }
        return error.SchemaViolation;
    }

    fn child(self: Validator, path: []const u8, suffix: []const u8) ![]const u8 {
        return std.fmt.allocPrint(self.arena, "{s}{s}", .{ path, suffix });
    }

    fn validate(self: Validator, schema_in: std.json.Value, doc: std.json.Value, path: []const u8) !void {
        const schema = try self.resolve(schema_in);

        if (schema.object.get("const")) |c| {
            if (!scalarEql(c, doc)) return self.fail(path, "const mismatch", c.string);
        }

        if (schema.object.get("enum")) |e| {
            var ok = false;
            for (e.array.items) |cand| {
                if (scalarEql(cand, doc)) {
                    ok = true;
                    break;
                }
            }
            if (!ok) return self.fail(path, "value outside enum", @tagName(doc));
        }

        if (schema.object.get("type")) |t| {
            const ok = switch (t) {
                .string => typeMatches(t.string, doc),
                .array => blk: {
                    for (t.array.items) |n| if (typeMatches(n.string, doc)) break :blk true;
                    break :blk false;
                },
                else => return error.UnsupportedTypeForm,
            };
            if (!ok) return self.fail(path, "type mismatch", @tagName(doc));
        }

        if (schema.object.get("properties")) |props| {
            if (doc != .object) return self.fail(path, "expected an object", @tagName(doc));

            if (schema.object.get("required")) |req| {
                for (req.array.items) |r| {
                    if (doc.object.get(r.string) == null) {
                        return self.fail(path, "emitter dropped a required property", r.string);
                    }
                }
            }

            // additionalProperties:false — catch a field the emitter added but
            // the schema never described. This is the drift that silently
            // breaks consumers who trusted the schema.
            if (schema.object.get("additionalProperties")) |ap| {
                if (ap == .bool and ap.bool == false) {
                    var it = doc.object.iterator();
                    while (it.next()) |kv| {
                        if (props.object.get(kv.key_ptr.*) == null) {
                            return self.fail(path, "emitter wrote a property absent from the schema", kv.key_ptr.*);
                        }
                    }
                }
            }

            var it = doc.object.iterator();
            while (it.next()) |kv| {
                const sub = props.object.get(kv.key_ptr.*) orelse continue;
                const sep = try self.child(path, ".");
                try self.validate(sub, kv.value_ptr.*, try self.child(sep, kv.key_ptr.*));
            }
        }

        if (schema.object.get("items")) |items| {
            if (doc != .array) return self.fail(path, "expected an array", @tagName(doc));
            for (doc.array.items, 0..) |el, i| {
                const label = try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ path, i });
                try self.validate(items, el, label);
            }
        }

        // Length/count bounds. JSON Schema `maxLength` counts Unicode code
        // points, not UTF-8 bytes; the parser's byte limits stay normative in
        // prose and can only be stricter than this check for multibyte input.
        // `pattern` is deliberately not implemented: the subset of regex it
        // would need is unbounded, and no repo schema relies on it being
        // enforced mechanically (bounds remain prose-documented).
        // Bounds apply to string values only; `null` is skipped so schemas
        // that allow `["string", "null"]` (optional frontmatter fields) work.
        if (schema.object.get("minLength")) |ml| {
            if (doc == .string and ml.integer > 0 and codepointLen(doc.string) < @as(usize, @intCast(ml.integer))) {
                return self.fail(path, "string shorter than minLength", "");
            }
        }
        if (schema.object.get("maxLength")) |ml| {
            if (doc == .string and codepointLen(doc.string) > @as(usize, @intCast(ml.integer))) {
                return self.fail(path, "string longer than maxLength", "");
            }
        }
        if (schema.object.get("minItems")) |mi| {
            if (doc != .array) return self.fail(path, "expected an array for minItems", @tagName(doc));
            if (mi.integer > 0 and doc.array.items.len < @as(usize, @intCast(mi.integer))) {
                return self.fail(path, "array shorter than minItems", "");
            }
        }
        if (schema.object.get("maxItems")) |mi| {
            if (doc != .array) return self.fail(path, "expected an array for maxItems", @tagName(doc));
            if (doc.array.items.len > @as(usize, @intCast(mi.integer))) {
                return self.fail(path, "array longer than maxItems", "");
            }
        }
    }
};

fn readAlloc(io: Io, dir: Io.Dir, rel: []const u8, gpa: std.mem.Allocator) ![]u8 {
    var file = try dir.openFile(io, rel, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return try reader.interface.allocRemaining(gpa, .unlimited);
}

fn checkArtifact(
    io: Io,
    gpa: std.mem.Allocator,
    artifact_rel: []const u8,
    schema_rel: []const u8,
) !void {
    const cwd = Io.Dir.cwd();

    const schema_bytes = try readAlloc(io, cwd, schema_rel, gpa);
    defer gpa.free(schema_bytes);
    const doc_bytes = try readAlloc(io, cwd, artifact_rel, gpa);
    defer gpa.free(doc_bytes);

    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer schema_parsed.deinit();
    var doc_parsed = try std.json.parseFromSlice(std.json.Value, gpa, doc_bytes, .{});
    defer doc_parsed.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    const v: Validator = .{ .root = schema_parsed.value, .arena = arena_state.allocator() };
    try v.validate(schema_parsed.value, doc_parsed.value, std.fs.path.basename(artifact_rel));
}

test "published IR schemas match freshly emitted IR" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    Io.Dir.cwd().deleteTree(io, work_dir) catch {};
    defer Io.Dir.cwd().deleteTree(io, work_dir) catch {};

    var result = try pipeline.run(io, gpa, .{
        .content_root = "content",
        .out_dir = work_dir,
        .quiet = true,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);

    try checkArtifact(io, gpa, work_dir ++ "/manifest.json", "docs/contracts/schemas/ir-manifest-0.2.0.schema.json");
    try checkArtifact(io, gpa, work_dir ++ "/graph.json", "docs/contracts/schemas/ir-graph-0.2.0.schema.json");
    try checkArtifact(io, gpa, work_dir ++ "/completion.json", "docs/contracts/schemas/boris-completion-1.schema.json");
    try checkArtifact(io, gpa, work_dir ++ "/build-report.json", "docs/contracts/schemas/ir-build-report-0.2.0.schema.json");
}

test "the published IR 0.4 graph schema matches freshly emitted recipe IR" {
    // A schema nobody validates is prose. The Cooklang fixture is the only tree
    // that emits the `recipe` facet, so it is the only thing that can prove the
    // 0.4 schema describes what the emitter actually writes.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const cook_work = output_root ++ "/ir-schema-conformance-cook";
    Io.Dir.cwd().deleteTree(io, cook_work) catch {};
    defer Io.Dir.cwd().deleteTree(io, cook_work) catch {};

    var result = try pipeline.run(io, gpa, .{
        .content_root = "docs/contracts/fixtures/cooklang-compatibility/content",
        .out_dir = cook_work,
        .quiet = true,
        .input_format = .cook,
    });
    defer result.deinit();
    try std.testing.expect(result.ok);

    try checkArtifact(io, gpa, cook_work ++ "/graph.json", "docs/contracts/schemas/ir-graph-0.4.0.schema.json");
}

test "the published recipe-scale view schema matches a freshly rendered view" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    var compiled = try pipeline.compile(io, gpa, .{
        .content_root = "docs/contracts/fixtures/cooklang-compatibility/content",
        .quiet = true,
        .input_format = .cook,
    });
    defer compiled.deinit();
    try std.testing.expect(compiled.ok);

    const factor = try recipe_scale.parseFactor("2");
    const bytes = try recipe_scale_view.renderFromCompile(gpa, &compiled, "carbonara", factor, null, "");
    defer gpa.free(bytes);

    const schema_bytes = try readAlloc(io, Io.Dir.cwd(), "docs/contracts/schemas/recipe-scale-view-0.2.0.schema.json", gpa);
    defer gpa.free(schema_bytes);
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer schema_parsed.deinit();
    var doc_parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
    defer doc_parsed.deinit();
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const v: Validator = .{ .root = schema_parsed.value, .arena = arena_state.allocator() };
    try v.validate(schema_parsed.value, doc_parsed.value, "recipe-scale-view");

    // The additive `vcsRevision` provenance field (#781) must also validate
    // when a token is present (production binaries carry the baked value).
    const with_token = try recipe_scale_view.renderFromCompile(gpa, &compiled, "carbonara", factor, null, "a8ef247");
    defer gpa.free(with_token);
    var token_doc = try std.json.parseFromSlice(std.json.Value, gpa, with_token, .{});
    defer token_doc.deinit();
    try v.validate(schema_parsed.value, token_doc.value, "recipe-scale-view");
}

test "conformance validator actually rejects drift" {
    // Guard against a validator that silently passes everything: a schema this
    // strict must reject both an added and a missing property.
    const gpa = std.testing.allocator;

    const schema_src =
        \\{"type":"object","required":["a"],"additionalProperties":false,
        \\ "properties":{"a":{"type":"string"}}}
    ;
    var schema = try std.json.parseFromSlice(std.json.Value, gpa, schema_src, .{});
    defer schema.deinit();

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const v: Validator = .{ .root = schema.value, .arena = arena_state.allocator(), .verbose = false };

    var good = try std.json.parseFromSlice(std.json.Value, gpa, "{\"a\":\"x\"}", .{});
    defer good.deinit();
    try v.validate(schema.value, good.value, "probe");

    var missing = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer missing.deinit();
    try std.testing.expectError(error.SchemaViolation, v.validate(schema.value, missing.value, "probe"));

    var extra = try std.json.parseFromSlice(std.json.Value, gpa, "{\"a\":\"x\",\"b\":1}", .{});
    defer extra.deinit();
    try std.testing.expectError(error.SchemaViolation, v.validate(schema.value, extra.value, "probe"));

    var wrong_type = try std.json.parseFromSlice(std.json.Value, gpa, "{\"a\":1}", .{});
    defer wrong_type.deinit();
    try std.testing.expectError(error.SchemaViolation, v.validate(schema.value, wrong_type.value, "probe"));

    // The length/count keywords must be enforced, not just documented:
    // a schema stating a bound that the validator never checks is drift
    // in disguise.
    const bounded_src =
        \\{"type":"object","additionalProperties":false,
        \\ "properties":{"s":{"type":"string","maxLength":3,"minLength":2},
        \\                  "a":{"type":"array","maxItems":2}},
        \\ "required":["s","a"]}
    ;
    var bounded = try std.json.parseFromSlice(std.json.Value, gpa, bounded_src, .{});
    defer bounded.deinit();
    var bound_arena = std.heap.ArenaAllocator.init(gpa);
    defer bound_arena.deinit();
    const vb: Validator = .{ .root = bounded.value, .arena = bound_arena.allocator(), .verbose = false };

    var ok_bounded = try std.json.parseFromSlice(std.json.Value, gpa, "{\"s\":\"abc\",\"a\":[1,2]}", .{});
    defer ok_bounded.deinit();
    try vb.validate(bounded.value, ok_bounded.value, "probe");

    var too_long = try std.json.parseFromSlice(std.json.Value, gpa, "{\"s\":\"abcd\",\"a\":[]}", .{});
    defer too_long.deinit();
    try std.testing.expectError(error.SchemaViolation, vb.validate(bounded.value, too_long.value, "probe"));

    var too_many = try std.json.parseFromSlice(std.json.Value, gpa, "{\"s\":\"ab\",\"a\":[1,2,3]}", .{});
    defer too_many.deinit();
    try std.testing.expectError(error.SchemaViolation, vb.validate(bounded.value, too_many.value, "probe"));
}

/// JSON view of parsed frontmatter: the closed key set, null where absent.
/// This is the shape `boris-frontmatter-1.schema.json` describes; editors
/// convert parsed frontmatter source to it before validating.
fn frontmatterJsonView(arena: std.mem.Allocator, m: parser.FrontmatterView) !std.json.Value {
    var obj: std.json.ObjectMap = try .init(arena, &.{}, &.{});
    try obj.put(arena, "id", if (m.id) |v| .{ .string = v } else .null);
    try obj.put(arena, "title", if (m.title) |v| .{ .string = v } else .null);
    try obj.put(arena, "parent", if (m.parent) |v| .{ .string = v } else .null);
    try obj.put(arena, "status", if (m.status) |s| .{ .string = s.name() } else .null);

    var tags: std.json.Array = .init(arena);
    for (m.tagsSlice()) |t| try tags.append(.{ .string = t });
    try obj.put(arena, "tags", .{ .array = tags });

    var relations: std.json.Array = .init(arena);
    for (m.relationsSlice()) |r| {
        var rel: std.json.ObjectMap = try .init(arena, &.{}, &.{});
        try rel.put(arena, "kind", .{ .string = r.kind.name() });
        try rel.put(arena, "target", .{ .string = r.target });
        try relations.append(.{ .object = rel });
    }
    try obj.put(arena, "relations", .{ .array = relations });

    try obj.put(arena, "published_at", if (m.published_at) |v| .{ .string = v } else .null);
    try obj.put(arena, "summary", if (m.summary) |v| .{ .string = v } else .null);
    try obj.put(arena, "servings", if (m.servings) |s| .{ .string = s.authored } else .null);
    return .{ .object = obj };
}

test "frontmatter schema matches the product parser on fixture trees" {
    // A schema nobody validates is prose. Parse every authoring page in the
    // main tree and the contract fixture trees with the product parser, render
    // the JSON view, and check it against the published frontmatter schema —
    // drift in either direction fails.
    const io = std.testing.io;
    const gpa = std.testing.allocator;

    const schema_bytes = try readAlloc(io, Io.Dir.cwd(), "docs/contracts/schemas/boris-frontmatter-1.schema.json", gpa);
    defer gpa.free(schema_bytes);
    var schema_parsed = try std.json.parseFromSlice(std.json.Value, gpa, schema_bytes, .{});
    defer schema_parsed.deinit();

    const roots = [_][]const u8{
        "content",
        "docs/contracts/fixtures/valid/content",
        "docs/contracts/fixtures/semantic-relations/content",
    };
    for (roots) |root| {
        var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".md")) continue;
            const source = try readAlloc(io, dir, entry.path, gpa);
            defer gpa.free(source);
            const parsed = parser.parse(source);
            try std.testing.expect(parsed.isOk());

            var arena_state = std.heap.ArenaAllocator.init(gpa);
            defer arena_state.deinit();
            const view = try frontmatterJsonView(arena_state.allocator(), parsed.doc.meta);
            const v: Validator = .{ .root = schema_parsed.value, .arena = arena_state.allocator() };
            const label = try std.fmt.allocPrint(arena_state.allocator(), "{s}/{s}", .{ root, entry.path });
            try v.validate(schema_parsed.value, view, label);
        }
    }
}
