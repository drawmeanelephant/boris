//! Native macOS/Linux HTTPS adapter for AT Protocol identity discovery.
//!
//! The adapter owns a fresh `std.http.Client`, never loads proxy environment
//! variables, never installs cookies or credentials, never follows redirects,
//! and races each complete request against an explicit timeout. Its filtered I/O
//! vtable checks the concrete resolved IP address immediately before every
//! socket connection, so hostname validation is not misrepresented as DNS
//! rebinding protection.

const std = @import("std");
const builtin = @import("builtin");
const transport = @import("atproto_transport.zig");

const ConnectFn = @TypeOf(@as(std.Io.VTable, undefined).netConnectIp);
const max_registered_io = 8;

const RegistryEntry = struct {
    userdata: ?*anyopaque,
    original: ConnectFn,
    references: usize,
};

var registry_lock: std.atomic.Value(bool) = .init(false);
var registry: [max_registered_io]?RegistryEntry = @splat(null);

pub const StdTransport = struct {
    allocator: std.mem.Allocator,
    original_io: std.Io,
    filtered_vtable: std.Io.VTable,
    filtered_io: std.Io,
    http: std.http.Client,
    request_mutex: std.Io.Mutex = .init,

    /// Allocates the adapter so the self-referential filtered vtable remains
    /// at a stable address for its whole lifetime.
    pub fn create(allocator: std.mem.Allocator, io: std.Io) transport.Error!*StdTransport {
        if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.ConnectFailed;
        try registerIo(io.userdata, io.vtable.netConnectIp);
        errdefer unregisterIo(io.userdata);

        const self = try allocator.create(StdTransport);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .original_io = io,
            .filtered_vtable = io.vtable.*,
            .filtered_io = undefined,
            .http = undefined,
        };
        self.filtered_vtable.netConnectIp = checkedConnectIp;
        self.filtered_io = .{ .userdata = io.userdata, .vtable = &self.filtered_vtable };
        self.http = .{ .allocator = allocator, .io = self.filtered_io };
        self.http.read_buffer_size = 16 * 1024;
        self.http.write_buffer_size = 1024;
        // `http_proxy` and `https_proxy` deliberately remain null. In
        // particular, do not call std.http.Client.initDefaultProxies.
        return self;
    }

    pub fn destroy(self: *StdTransport) void {
        self.request_mutex.lockUncancelable(self.filtered_io);
        self.http.deinit();
        unregisterIo(self.original_io.userdata);
        const allocator = self.allocator;
        self.request_mutex.unlock(self.filtered_io);
        allocator.destroy(self);
    }

    pub fn client(self: *StdTransport) transport.Client {
        return .{ .context = self, .request_fn = perform };
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request_value: transport.Request) transport.Error!transport.Response {
        const self: *StdTransport = @ptrCast(@alignCast(context));
        self.request_mutex.lockUncancelable(self.filtered_io);
        defer self.request_mutex.unlock(self.filtered_io);

        const FetchResult = transport.Error!transport.Response;
        const TimerResult = std.Io.Cancelable!void;
        const Race = union(enum) { fetch: FetchResult, timer: TimerResult };
        var race_buffer: [2]Race = undefined;
        var race: std.Io.Select(Race) = .init(self.filtered_io, &race_buffer);
        race.async(.fetch, fetchTask, .{ self, allocator, request_value });
        race.async(.timer, timeoutTask, .{ self.filtered_io, request_value.limits.timeout_ms });

        const first = race.await() catch {
            drainRace(&race);
            return error.Timeout;
        };
        return switch (first) {
            .fetch => |result| result: {
                drainRace(&race);
                break :result result;
            },
            .timer => timeout: {
                drainRace(&race);
                break :timeout error.Timeout;
            },
        };
    }

    fn fetchTask(self: *StdTransport, allocator: std.mem.Allocator, request_value: transport.Request) transport.Error!transport.Response {
        if (request_value.method != .get) return error.UnexpectedRequest;
        if (request_value.headers.len != 1 or
            !std.ascii.eqlIgnoreCase(request_value.headers[0].name, "accept")) return error.UnexpectedRequest;
        const accept = request_value.headers[0].value;
        if (!std.mem.eql(u8, accept, "application/json") and
            !std.mem.eql(u8, accept, "text/plain")) return error.UnexpectedRequest;
        if (!std.mem.startsWith(u8, request_value.url, "https://")) return error.UnsafeTarget;
        const uri = std.Uri.parse(request_value.url) catch return error.UnsafeTarget;
        if (uri.host == null or uri.user != null or uri.password != null or uri.fragment != null) return error.UnsafeTarget;

        const extra_headers = [_]std.http.Header{.{ .name = "accept", .value = accept }};
        var request = self.http.request(.GET, uri, .{
            .keep_alive = false,
            .redirect_behavior = .unhandled,
            .headers = .{
                .user_agent = .omit,
                .accept_encoding = .omit,
            },
            .extra_headers = &extra_headers,
        }) catch |err| return mapOpenError(err);
        defer request.deinit();
        request.sendBodiless() catch |err| return mapIoError(err);

        var response = request.receiveHead(&.{}) catch |err| return mapHeadError(err);
        if (response.head.status.class() == .redirect and request_value.redirect_policy == .forbid) {
            return error.RedirectRejected;
        }
        if (response.head.content_encoding != .identity) return error.InvalidResponse;
        if (response.head.content_length) |length| {
            if (length > request_value.limits.max_body_bytes) return error.ResponseTooLarge;
        }

        var header_storage: [64]transport.Header = undefined;
        var header_count: usize = 0;
        var total_header_bytes: usize = 0;
        var iterator = response.head.iterateHeaders();
        while (iterator.next()) |header| {
            if (header_count >= request_value.limits.max_header_count or header_count >= header_storage.len) return error.TooManyHeaders;
            if (header.name.len > request_value.limits.max_header_name_bytes) return error.HeaderTooLarge;
            if (header.value.len > request_value.limits.max_header_value_bytes) return error.HeaderTooLarge;
            total_header_bytes = std.math.add(usize, total_header_bytes, header.name.len + header.value.len) catch return error.HeaderTooLarge;
            if (total_header_bytes > request_value.limits.max_header_bytes) return error.HeaderTooLarge;
            header_storage[header_count] = .{ .name = header.name, .value = header.value };
            header_count += 1;
        }

        // The std HTTP reader may reuse the head buffer for body bytes. Copy
        // every header before creating the body reader so response metadata
        // cannot be invalidated or overwritten underneath us.
        var owned_response = try transport.Response.initCopy(
            allocator,
            @intFromEnum(response.head.status),
            header_storage[0..header_count],
            "",
            request_value.limits,
        );
        errdefer owned_response.deinit();

        const body_capacity = std.math.add(usize, request_value.limits.max_body_bytes, 1) catch return error.ResponseTooLarge;
        const body_storage = try allocator.alloc(u8, body_capacity);
        defer allocator.free(body_storage);
        var body_writer: std.Io.Writer = .fixed(body_storage);
        var transfer_buffer: [64]u8 = undefined;
        const reader = response.reader(&transfer_buffer);
        _ = reader.streamRemaining(&body_writer) catch |err| {
            if (body_writer.end >= request_value.limits.max_body_bytes) return error.ResponseTooLarge;
            return mapIoError(err);
        };
        const body = body_writer.buffered();
        if (body.len > request_value.limits.max_body_bytes) return error.ResponseTooLarge;
        const owned_body = try allocator.dupe(u8, body);
        allocator.free(owned_response.body);
        owned_response.body = owned_body;
        return owned_response;
    }
};

fn timeoutTask(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    return (std.Io.Timeout{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    } }).sleep(io);
}

fn drainRace(race: anytype) void {
    while (race.cancel()) |remaining| switch (remaining) {
        .fetch => |result| if (result) |response_value| {
            var response = response_value;
            response.deinit();
        } else |_| {},
        .timer => {},
    };
}

fn registerIo(userdata: ?*anyopaque, original: ConnectFn) transport.Error!void {
    if (userdata == null) return error.UnsafeTarget;
    lockRegistry();
    defer unlockRegistry();
    for (&registry) |*slot| {
        if (slot.*) |*entry| {
            if (entry.userdata == userdata) {
                if (entry.original != original) return error.UnsafeTarget;
                entry.references += 1;
                return;
            }
        }
    }
    for (&registry) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .userdata = userdata, .original = original, .references = 1 };
            return;
        }
    }
    return error.ConnectFailed;
}

fn unregisterIo(userdata: ?*anyopaque) void {
    lockRegistry();
    defer unlockRegistry();
    for (&registry) |*slot| {
        if (slot.*) |*entry| {
            if (entry.userdata != userdata) continue;
            entry.references -= 1;
            if (entry.references == 0) slot.* = null;
            return;
        }
    }
}

fn checkedConnectIp(
    userdata: ?*anyopaque,
    address: *const std.Io.net.IpAddress,
    options: std.Io.net.IpAddress.ConnectOptions,
) std.Io.net.IpAddress.ConnectError!std.Io.net.Socket {
    if (!isPublicAddress(address.*)) return error.AccessDenied;
    const original: ConnectFn = original: {
        lockRegistry();
        defer unlockRegistry();
        for (registry) |slot| {
            const entry = slot orelse continue;
            if (entry.userdata == userdata) break :original entry.original;
        }
        return error.AccessDenied;
    };
    return original(userdata, address, options);
}

fn lockRegistry() void {
    while (registry_lock.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockRegistry() void {
    registry_lock.store(false, .release);
}

/// Conservative global-unicast policy. URL hostname validation remains a
/// separate concern; every DNS result is checked again at the socket seam.
pub fn isPublicAddress(address: std.Io.net.IpAddress) bool {
    return switch (address) {
        .ip4 => |ip4| isPublicIpv4(ip4.bytes),
        .ip6 => |ip6| isPublicIpv6(ip6.bytes),
    };
}

fn isPublicIpv4(bytes: [4]u8) bool {
    const a = bytes[0];
    const b = bytes[1];
    if (a == 0 or a == 10 or a == 127 or a >= 224) return false;
    if (a == 100 and b >= 64 and b <= 127) return false;
    if (a == 169 and b == 254) return false;
    if (a == 172 and b >= 16 and b <= 31) return false;
    if (a == 192 and (b == 0 or b == 168)) return false;
    if (a == 198 and (b == 18 or b == 19 or (b == 51 and bytes[2] == 100))) return false;
    if (a == 203 and b == 0 and bytes[2] == 113) return false;
    return true;
}

fn isPublicIpv6(bytes: [16]u8) bool {
    const mapped_prefix = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
    if (std.mem.eql(u8, bytes[0..12], &mapped_prefix)) return isPublicIpv4(bytes[12..16].*);
    // Only the IETF global-unicast 2000::/3 block is eligible.
    if ((bytes[0] & 0xe0) != 0x20) return false;
    // Documentation range 2001:db8::/32.
    if (bytes[0] == 0x20 and bytes[1] == 0x01 and bytes[2] == 0x0d and bytes[3] == 0xb8) return false;
    return true;
}

fn mapOpenError(err: anyerror) transport.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.AccessDenied => error.UnsafeTarget,
        error.UnknownHostName,
        error.NameServerFailure,
        error.NoAddressReturned,
        => error.DnsFailed,
        error.TlsInitializationFailed,
        error.CertificateBundleLoadFailure,
        => error.TlsFailed,
        error.Timeout, error.Canceled => error.Timeout,
        else => error.ConnectFailed,
    };
}

fn mapHeadError(err: anyerror) transport.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.HttpHeadersOversize => error.HeaderTooLarge,
        error.Timeout, error.Canceled => error.Timeout,
        else => error.InvalidResponse,
    };
}

fn mapIoError(err: anyerror) transport.Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.Timeout, error.Canceled => error.Timeout,
        else => error.ConnectFailed,
    };
}

test "connection target policy rejects non-public IPv4 ranges" {
    const IpAddress = std.Io.net.IpAddress;
    inline for (.{
        "0.0.0.0",     "10.0.0.1",        "100.64.0.1",  "127.0.0.1",
        "169.254.1.1", "172.16.0.1",      "192.168.1.1", "198.18.0.1",
        "224.0.0.1",   "255.255.255.255",
    }) |text| try std.testing.expect(!isPublicAddress(try IpAddress.parse(text, 443)));
    try std.testing.expect(isPublicAddress(try IpAddress.parse("8.8.8.8", 443)));
}

test "connection target policy rejects local, unique-local, link-local, multicast, and mapped IPv6" {
    const IpAddress = std.Io.net.IpAddress;
    inline for (.{ "::", "::1", "fc00::1", "fd00::1", "fe80::1", "ff02::1", "2001:db8::1", "::ffff:127.0.0.1" }) |text| {
        try std.testing.expect(!isPublicAddress(try IpAddress.parse(text, 443)));
    }
    try std.testing.expect(isPublicAddress(try IpAddress.parse("2606:4700:4700::1111", 443)));
}

test "native adapter initializes without ambient proxy configuration" {
    const adapter = try StdTransport.create(std.testing.allocator, std.testing.io);
    defer adapter.destroy();
    try std.testing.expect(adapter.http.http_proxy == null);
    try std.testing.expect(adapter.http.https_proxy == null);
    _ = adapter.client();
}
