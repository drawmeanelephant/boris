const std = @import("std");
const Io = std.Io;
const cache = @import("cache.zig");
const publication_checks = @import("publication_checks.zig");

pub const FileBinding = struct {
    bytes: usize,
    sha256: [64]u8,
};

pub fn bindingEqual(a: FileBinding, b: FileBinding) bool {
    return a.bytes == b.bytes and std.mem.eql(u8, &a.sha256, &b.sha256);
}

pub fn EvidenceInput(comptime E: type) type {
    return struct {
        file: Io.File = undefined,
        buffer: [64 * 1024]u8 = undefined,
        file_reader: Io.File.Reader = undefined,
        reader: Io.Reader = undefined,
        digest: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
        count: usize = 0,
        ended: bool = false,

        /// Committed evidence reports are metadata-scale JSON inventories,
        /// never payload-sized; a larger file is a malformed report, not a
        /// bigger allocation. Reject excess bytes as a read failure, not EOF,
        /// so a valid JSON prefix cannot hide an oversized suffix. Matches
        /// `publication_evidence_state.max_state_bytes`.
        pub const max_bytes: usize = 64 * 1024 * 1024;

        const Self = @This();

        pub fn open(self: *Self, io: Io, root: Io.Dir, path: []const u8, missing_error: E) E!void {
            self.* = .{};
            self.file = publication_checks.openFileNoFollow(io, root, path) catch
                return missing_error;
            // Positional readers: no-follow handles are asynchronous on
            // Windows, so offset-less streaming reads cannot succeed there.
            self.file_reader = self.file.reader(io, &.{});
            self.reader = .{
                .vtable = &.{ .stream = stream },
                .buffer = &self.buffer,
                .seek = 0,
                .end = 0,
            };
        }

        fn stream(r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
            if (limit == .nothing) return 0;
            const self: *Self = @alignCast(@fieldParentPtr("reader", r));
            const dest = limit.slice(try w.writableSliceGreedy(1));
            // Probe one byte beyond the inclusive cap, even when JSON ended
            // exactly at the bound. Never synthesize a successful EOF there.
            const chunk = dest[0..@min(dest.len, max_bytes - self.count + 1)];
            const n = try self.file_reader.interface.readSliceShort(chunk);
            if (n == 0) {
                self.ended = true;
                return error.EndOfStream;
            }
            if (n > max_bytes - self.count) return error.ReadFailed;
            self.digest.update(chunk[0..n]);
            self.count += n;
            w.advance(n);
            return n;
        }

        /// Hash and count the same bytes the parser consumes, without a
        /// replay buffer, reopening the path, or rewinding the handle.
        pub fn parseReader(self: *Self) *Io.Reader {
            return &self.reader;
        }

        pub fn close(self: *Self, io: Io) void {
            self.file.close(io);
        }

        pub fn finish(self: *Self) FileBinding {
            std.debug.assert(self.ended and self.reader.bufferedLen() == 0);
            var digest: [32]u8 = undefined;
            self.digest.final(&digest);
            return .{ .bytes = self.count, .sha256 = cache.hexDigest(digest) };
        }
    };
}

test "evidence reader hashes the complete document at the cap and rejects excess whitespace" {
    const io = std.testing.io;
    const Input = EvidenceInput(error{ OutOfMemory, InvalidArtifactsReport });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    for ([_]usize{ Input.max_bytes, Input.max_bytes + 1 }) |size| {
        var file = try tmp.dir.createFile(io, "bounded.json", .{});
        var buf: [64 * 1024]u8 = @splat(' ');
        var writer = file.writer(io, &buf);
        try writer.interface.writeAll("{}");
        try writer.interface.splatByteAll(' ', size - 2);
        try writer.interface.flush();
        file.close(io);
        var input: Input = .{};
        try input.open(io, tmp.dir, "bounded.json", error.InvalidArtifactsReport);
        defer input.close(io);
        // The 64 MiB file must parse with only a small allocation budget.
        var allocations: [32 * 1024]u8 = undefined;
        var fixed = std.heap.FixedBufferAllocator.init(&allocations);
        const parser_gpa = fixed.allocator();
        var json = std.json.Reader.init(parser_gpa, input.parseReader());
        defer json.deinit();
        const parsed = std.json.parseFromTokenSource(std.json.Value, parser_gpa, &json, .{});
        if (size > Input.max_bytes) {
            try std.testing.expectError(error.ReadFailed, parsed);
        } else {
            var value = try parsed;
            defer value.deinit();
            const binding = input.finish();
            try std.testing.expectEqual(size, binding.bytes);
            var expected = std.crypto.hash.sha2.Sha256.init(.{});
            expected.update("{}");
            const spaces: [4096]u8 = @splat(' ');
            var remaining = size - 2;
            while (remaining != 0) {
                const n = @min(remaining, spaces.len);
                expected.update(spaces[0..n]);
                remaining -= n;
            }
            var digest: [32]u8 = undefined;
            expected.final(&digest);
            try std.testing.expectEqualStrings(&cache.hexDigest(digest), &binding.sha256);
        }
    }
}

test "evidence reader propagates an input failure rather than manufacturing EOF" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "report.json", .data = "{}" });
    const Input = EvidenceInput(error{InvalidArtifactsReport});
    var input: Input = .{};
    try input.open(io, tmp.dir, "report.json", error.InvalidArtifactsReport);
    defer input.close(io);
    input.file_reader.interface = .failing;
    var json = std.json.Reader.init(std.testing.allocator, input.parseReader());
    defer json.deinit();
    try std.testing.expectError(error.ReadFailed, std.json.parseFromTokenSource(std.json.Value, std.testing.allocator, &json, .{}));
}
