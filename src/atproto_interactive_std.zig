//! Native macOS/Linux composition for one ATProto OAuth authorization.
//!
//! The function opens an ephemeral loopback listener before PAR, launches the
//! system browser without a shell, accepts one callback, and exchanges one
//! code. It returns only an in-memory session and creates no files or caches.

const std = @import("std");
const authorization = @import("atproto_authorization.zig");
const browser = @import("atproto_browser_std.zig");
const identity = @import("atproto_identity.zig");
const loopback = @import("atproto_loopback_std.zig");
const transport = @import("atproto_transport.zig");

pub const callback_timeout_ms: u32 = 10 * 60 * 1000;

pub const Error = authorization.Error || browser.Error || loopback.Error || error{EntropyUnavailable};

/// Perform one interactive authorization for an already resolved and verified
/// account. The supplied transport retains the discovery adapter's HTTPS,
/// redirect, timeout, and connection-target policies.
pub fn authorize(
    allocator: std.mem.Allocator,
    io: std.Io,
    client: transport.Client,
    account: identity.DiscoveredAccount,
) Error!authorization.AuthorizedSession {
    var listener = try loopback.Listener.init(io);
    defer listener.deinit();
    var redirect_buffer: [256]u8 = undefined;
    const redirect_uri = try listener.redirectUri(&redirect_buffer);

    var entropy: authorization.SessionEntropy = undefined;
    std.Io.randomSecure(io, std.mem.asBytes(&entropy)) catch return error.EntropyUnavailable;
    defer erase(std.mem.asBytes(&entropy));
    var proof_context = NativeProofSource{ .io = io };
    var pending = try authorization.begin(
        allocator,
        client,
        account,
        redirect_uri,
        entropy,
        proof_context.source(),
    );
    defer pending.deinit();

    const browser_url = try pending.browserUrl(allocator);
    defer {
        erase(browser_url);
        allocator.free(browser_url);
    }
    try browser.open(allocator, io, browser_url);

    const par_timeout_ms = std.math.mul(u64, pending.request_uri_expires_in, 1000) catch std.math.maxInt(u64);
    const wait_timeout_ms: u32 = @intCast(@min(par_timeout_ms, callback_timeout_ms));
    const callback_target = try listener.waitTarget(allocator, wait_timeout_ms);
    defer {
        erase(callback_target);
        allocator.free(callback_target);
    }
    try pending.acceptCallback(callback_target);
    return pending.exchange(allocator, client, proof_context.source());
}

const NativeProofSource = struct {
    io: std.Io,

    fn source(self: *NativeProofSource) authorization.ProofSource {
        return .{ .context = self, .next_fn = next };
    }

    fn next(context: *anyopaque) authorization.Error!authorization.ProofMaterial {
        const self: *NativeProofSource = @ptrCast(@alignCast(context));
        var material: authorization.ProofMaterial = undefined;
        const now = std.Io.Timestamp.now(self.io, .real).toSeconds();
        if (now < 0) return error.InvalidWallClock;
        material.issued_at = @intCast(now);
        std.Io.randomSecure(self.io, &material.jti_entropy) catch return error.ProofUnavailable;
        std.Io.randomSecure(self.io, &material.signing_noise) catch {
            erase(&material.jti_entropy);
            return error.ProofUnavailable;
        };
        return material;
    }
};

fn erase(bytes: []u8) void {
    std.crypto.secureZero(u8, bytes);
}

test "native proof material uses explicit host capabilities" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{ .environ = std.process.Environ.empty });
    defer threaded.deinit();
    var context = NativeProofSource{ .io = threaded.io() };
    var material = try context.source().next();
    defer erase(std.mem.asBytes(&material));
    try std.testing.expect(material.issued_at > 1_700_000_000);
}
