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
        pass2_buffer: [64 * 1024]u8 = undefined,
        pass2: Io.File.Reader = undefined,

        const Self = @This();

        pub fn open(self: *Self, io: Io, root: Io.Dir, path: []const u8, missing_error: E) E!void {
            self.* = .{};
            self.file = publication_checks.openFileNoFollow(io, root, path) catch
                return missing_error;
            self.pass1 = self.file.readerStreaming(io, &self.pass1_buffer);
        }

        pub fn hashPass(self: *Self, fail_error: E) E!void {
            var chunk: [64 * 1024]u8 = undefined;
            while (true) {
                const n = self.pass1.interface.readSliceShort(&chunk) catch
                    return fail_error;
                if (n == 0) break;
                self.digest.update(chunk[0..n]);
                self.count = std.math.add(usize, self.count, n) catch return fail_error;
            }
        }

        pub fn rewindForParse(self: *Self, io: Io, fail_error: E) E!void {
            io.vtable.fileSeekTo(io.userdata, self.file, 0) catch
                return fail_error;
            self.pass2 = self.file.readerStreaming(io, &self.pass2_buffer);
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
