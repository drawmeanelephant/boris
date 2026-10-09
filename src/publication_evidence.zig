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
        pass1_buffer: [64 * 1024]u8 = undefined,
        pass1: Io.File.Reader = undefined,
        digest: std.crypto.hash.sha2.Sha256 = std.crypto.hash.sha2.Sha256.init(.{}),
        count: usize = 0,
        bytes: std.ArrayList(u8) = .empty,
        pass2: Io.Reader = undefined,

        /// Committed evidence reports are metadata-scale JSON inventories,
        /// never payload-sized; a larger file is a malformed report, not a
        /// bigger allocation. This bounds the bytes `hashPass` collects so
        /// the single-pass read stays fail-closed: an oversized input is
        /// rejected with the caller's report error instead of an unbounded
        /// buffer. Matches `publication_evidence_state.max_state_bytes`.
        pub const max_bytes: usize = 64 * 1024 * 1024;

        const Self = @This();

        pub fn open(self: *Self, io: Io, root: Io.Dir, path: []const u8, missing_error: E) E!void {
            self.* = .{};
            self.file = publication_checks.openFileNoFollow(io, root, path) catch
                return missing_error;
            // Positional readers: no-follow handles are asynchronous on
            // Windows, so offset-less streaming reads cannot succeed there.
            self.pass1 = self.file.reader(io, &self.pass1_buffer);
        }

        /// The only read pass over the handle: every byte is counted, hashed
        /// for the binding, and collected so `parseReader` can replay it.
        pub fn hashPass(self: *Self, gpa: std.mem.Allocator, fail_error: E) E!void {
            var chunk: [64 * 1024]u8 = undefined;
            while (true) {
                const n = self.pass1.interface.readSliceShort(&chunk) catch
                    return fail_error;
                if (n == 0) break;
                self.digest.update(chunk[0..n]);
                self.count = std.math.add(usize, self.count, n) catch return fail_error;
                if (self.count > max_bytes) return fail_error;
                self.bytes.appendSlice(gpa, chunk[0..n]) catch return error.OutOfMemory;
            }
        }

        /// A reader over exactly the bytes `hashPass` collected. Replaying
        /// the payload from memory keeps the parse pass off the file handle:
        /// no-follow handles are asynchronous on Windows, where a second
        /// streaming read after rewinding the handle does not complete.
        pub fn parseReader(self: *Self) *Io.Reader {
            self.pass2 = Io.Reader.fixed(self.bytes.items);
            return &self.pass2;
        }

        pub fn close(self: *Self, io: Io) void {
            self.file.close(io);
        }

        pub fn finish(self: *Self) FileBinding {
            var digest: [32]u8 = undefined;
            self.digest.final(&digest);
            return .{ .bytes = self.count, .sha256 = cache.hexDigest(digest) };
        }
    };
}

test "hashPass collects up to max_bytes and rejects one byte past it" {
    const io = std.testing.io;
    const gpa = std.testing.allocator;
    const Input = EvidenceInput(error{ OutOfMemory, InvalidArtifactsReport });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Exactly at the bound the report is counted, hashed, collected, and
    // replayable: the cap is inclusive, not a stricter limit in disguise.
    {
        var file = try tmp.dir.createFile(io, "at-bound.json", .{});
        try file.setLength(io, Input.max_bytes);
        file.close(io);

        var input: Input = .{};
        try input.open(io, tmp.dir, "at-bound.json", error.InvalidArtifactsReport);
        defer input.close(io);
        try input.hashPass(gpa, error.InvalidArtifactsReport);
        defer input.bytes.deinit(gpa);
        try std.testing.expectEqual(Input.max_bytes, input.count);
        try std.testing.expectEqual(Input.max_bytes, input.bytes.items.len);
        try std.testing.expectEqual(Input.max_bytes, input.parseReader().bufferedLen());
    }

    // One byte over the bound fails closed with the caller's report error —
    // never OutOfMemory — and the buffer never exceeds the cap.
    {
        var file = try tmp.dir.createFile(io, "oversized.json", .{});
        try file.setLength(io, Input.max_bytes + 1);
        file.close(io);

        var input: Input = .{};
        try input.open(io, tmp.dir, "oversized.json", error.InvalidArtifactsReport);
        defer input.close(io);
        try std.testing.expectError(
            error.InvalidArtifactsReport,
            input.hashPass(gpa, error.InvalidArtifactsReport),
        );
        try std.testing.expect(input.bytes.items.len <= Input.max_bytes);
        input.bytes.deinit(gpa);
    }
}
