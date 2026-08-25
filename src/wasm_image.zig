//! Minimal WebAssembly binary inspector for the freestanding render gate.
//!
//! Parses only the import and export sections. Not a runtime.

const std = @import("std");

pub const Import = struct {
    module: []const u8,
    name: []const u8,
    kind: u8,
};

pub const Export = struct {
    name: []const u8,
    kind: u8,
};

pub const Image = struct {
    imports: []Import,
    exports: []Export,

    pub fn deinit(self: Image, gpa: std.mem.Allocator) void {
        for (self.imports) |im| {
            gpa.free(im.module);
            gpa.free(im.name);
        }
        gpa.free(self.imports);
        for (self.exports) |ex| gpa.free(ex.name);
        gpa.free(self.exports);
    }
};

const section_import: u8 = 2;
const section_export: u8 = 7;

pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) !Image {
    if (bytes.len < 8) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..4], "\x00asm")) return error.NotWasm;
    const version = std.mem.readInt(u32, bytes[4..8], .little);
    if (version != 1) return error.UnsupportedVersion;

    var imports: std.ArrayList(Import) = .empty;
    errdefer {
        for (imports.items) |im| {
            gpa.free(im.module);
            gpa.free(im.name);
        }
        imports.deinit(gpa);
    }
    var exports: std.ArrayList(Export) = .empty;
    errdefer {
        for (exports.items) |ex| gpa.free(ex.name);
        exports.deinit(gpa);
    }

    var i: usize = 8;
    while (i < bytes.len) {
        const id = bytes[i];
        i += 1;
        const size = try readU32Leb(&i, bytes);
        const end = i + size;
        if (end > bytes.len) return error.Truncated;
        const payload = bytes[i..end];
        i = end;
        switch (id) {
            section_import => try parseImports(gpa, payload, &imports),
            section_export => try parseExports(gpa, payload, &exports),
            else => {},
        }
    }

    return .{
        .imports = try imports.toOwnedSlice(gpa),
        .exports = try exports.toOwnedSlice(gpa),
    };
}

fn parseImports(gpa: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(Import)) !void {
    var i: usize = 0;
    const count = try readU32Leb(&i, payload);
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const module = try readName(gpa, &i, payload);
        errdefer gpa.free(module);
        const name = try readName(gpa, &i, payload);
        errdefer gpa.free(name);
        if (i >= payload.len) return error.Truncated;
        const kind = payload[i];
        i += 1;
        try skipImportDesc(kind, &i, payload);
        try out.append(gpa, .{ .module = module, .name = name, .kind = kind });
    }
}

fn parseExports(gpa: std.mem.Allocator, payload: []const u8, out: *std.ArrayList(Export)) !void {
    var i: usize = 0;
    const count = try readU32Leb(&i, payload);
    var n: u32 = 0;
    while (n < count) : (n += 1) {
        const name = try readName(gpa, &i, payload);
        errdefer gpa.free(name);
        if (i >= payload.len) return error.Truncated;
        const kind = payload[i];
        i += 1;
        _ = try readU32Leb(&i, payload); // index
        try out.append(gpa, .{ .name = name, .kind = kind });
    }
}

fn skipImportDesc(kind: u8, i: *usize, bytes: []const u8) !void {
    switch (kind) {
        0 => _ = try readU32Leb(i, bytes), // func typeidx
        1 => { // table
            if (i.* >= bytes.len) return error.Truncated;
            i.* += 1; // reftype
            try skipLimits(i, bytes);
        },
        2 => try skipLimits(i, bytes), // mem
        3 => { // global
            if (i.* >= bytes.len) return error.Truncated;
            i.* += 1; // valtype
            if (i.* >= bytes.len) return error.Truncated;
            i.* += 1; // mut
        },
        else => return error.UnknownImportKind,
    }
}

fn skipLimits(i: *usize, bytes: []const u8) !void {
    if (i.* >= bytes.len) return error.Truncated;
    const flags = bytes[i.*];
    i.* += 1;
    _ = try readU32Leb(i, bytes);
    if (flags & 1 != 0) _ = try readU32Leb(i, bytes);
}

fn readName(gpa: std.mem.Allocator, i: *usize, bytes: []const u8) ![]u8 {
    const len = try readU32Leb(i, bytes);
    if (i.* + len > bytes.len) return error.Truncated;
    const slice = bytes[i.* .. i.* + len];
    i.* += len;
    return try gpa.dupe(u8, slice);
}

fn readU32Leb(i: *usize, bytes: []const u8) !u32 {
    var result: u32 = 0;
    var shift: u5 = 0;
    while (true) {
        if (i.* >= bytes.len) return error.Truncated;
        const b = bytes[i.*];
        i.* += 1;
        const payload: u32 = b & 0x7f;
        if (shift >= 32 or (shift == 28 and payload > 0x0f)) return error.LebOverflow;
        result |= payload << shift;
        if (b & 0x80 == 0) return result;
        shift += 7;
    }
}
