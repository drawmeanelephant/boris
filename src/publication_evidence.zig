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
