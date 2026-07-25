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

const output_root = "test-output";
const work_dir = output_root ++ "/ir-schema-conformance";

/// Minimal validator for the JSON Schema subset the IR schemas use:
/// `$ref` (local `#/$defs/*`), `type`, `const`, `enum`, `required`,
/// `properties`, `additionalProperties: false`, and `items`.
const Validator = struct {
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
    try checkArtifact(io, gpa, work_dir ++ "/build-report.json", "docs/contracts/schemas/ir-build-report-0.2.0.schema.json");
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
}
