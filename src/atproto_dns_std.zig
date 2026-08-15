//! Native macOS/Linux DNS TXT adapter for AT Protocol handle resolution.
//!
//! The adapter reads the host resolver configuration, sends a bounded DNS
//! query directly to a configured recursive resolver, validates the response
//! source, random transaction ID, echoed question, packet structure, and TXT
//! chunk framing, and applies one whole-operation deadline. It performs no
//! caching and never invokes a subprocess or libc resolver API.

const std = @import("std");
const builtin = @import("builtin");
const dns = @import("atproto_dns.zig");

const max_dns_packet_bytes = 4096;
const max_native_records = 16;
const max_native_record_bytes = 2048;

pub const StdDns = struct {
    io: std.Io,

    pub fn init(io: std.Io) dns.Error!StdDns {
        if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.DnsFailed;
        return .{ .io = io };
    }

    pub fn client(self: *StdDns) dns.Client {
        return .{ .context = self, .query_txt_fn = perform };
    }

    fn perform(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
        limits: dns.Limits,
    ) dns.Error!dns.Response {
        const self: *StdDns = @ptrCast(@alignCast(context));
        const QueryResult = dns.Error!dns.Response;
        const TimerResult = std.Io.Cancelable!void;
        const Race = union(enum) { query: QueryResult, timer: TimerResult };
        var race_buffer: [2]Race = undefined;
        var race: std.Io.Select(Race) = .init(self.io, &race_buffer);
        race.async(.query, queryTask, .{ self.io, allocator, name, limits });
        race.async(.timer, timeoutTask, .{ self.io, limits.timeout_ms });

        const first = race.await() catch {
            drainRace(&race);
            return error.Timeout;
        };
        return switch (first) {
            .query => |result| result: {
                drainRace(&race);
                break :result result;
            },
            .timer => timeout: {
                drainRace(&race);
                break :timeout error.Timeout;
            },
        };
    }
};

fn queryTask(
    io: std.Io,
    allocator: std.mem.Allocator,
    name: []const u8,
    limits: dns.Limits,
) dns.Error!dns.Response {
    var id_bytes: [2]u8 = undefined;
    std.Io.randomSecure(io, &id_bytes) catch return error.DnsFailed;
    const id = std.mem.readInt(u16, &id_bytes, .big);
    var query_buffer: [512]u8 = undefined;
    const query = buildQuery(&query_buffer, id, name) catch return error.UnexpectedQuery;

    var resolver = std.Io.net.HostName.ResolvConf.init(io) catch return error.DnsFailed;
    var saw_timeout = false;
    for (resolver.nameservers()) |nameserver| {
        const local: std.Io.net.IpAddress = switch (nameserver) {
            .ip4 => .{ .ip4 = .unspecified(0) },
            .ip6 => .{ .ip6 = .unspecified(0) },
        };
        const socket = local.bind(io, .{ .mode = .dgram, .protocol = .udp }) catch continue;
        defer socket.close(io);
        socket.send(io, &nameserver, query) catch continue;

        var packet_buffer: [max_dns_packet_bytes]u8 = undefined;
        const message = socket.receiveTimeout(io, &packet_buffer, .{ .duration = .{
            .clock = .awake,
            .raw = .fromMilliseconds(limits.timeout_ms),
        } }) catch |err| switch (err) {
            error.Timeout => {
                saw_timeout = true;
                continue;
            },
            else => continue,
        };
        if (!message.from.eql(&nameserver) or message.flags.trunc) continue;
        return parseResponse(allocator, message.data, id, query[12..], limits);
    }
    return if (saw_timeout) error.Timeout else error.DnsFailed;
}

fn timeoutTask(io: std.Io, timeout_ms: u32) std.Io.Cancelable!void {
    return (std.Io.Timeout{ .duration = .{
        .clock = .awake,
        .raw = .fromMilliseconds(timeout_ms),
    } }).sleep(io);
}

fn drainRace(race: anytype) void {
    while (race.cancel()) |remaining| switch (remaining) {
        .query => |result| if (result) |response_value| {
            var response = response_value;
            response.deinit();
        } else |_| {},
        .timer => {},
    };
}

fn buildQuery(buffer: *[512]u8, id: u16, name: []const u8) dns.Error![]const u8 {
    try dns.validateQueryName(name);
    @memset(buffer[0..12], 0);
    std.mem.writeInt(u16, buffer[0..2], id, .big);
    std.mem.writeInt(u16, buffer[2..4], 0x0100, .big); // recursion desired
    std.mem.writeInt(u16, buffer[4..6], 1, .big);
    var index: usize = 12;
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (index + 1 + label.len + 5 > buffer.len) return error.UnexpectedQuery;
        buffer[index] = @intCast(label.len);
        index += 1;
        @memcpy(buffer[index..][0..label.len], label);
        index += label.len;
    }
    buffer[index] = 0;
    index += 1;
    std.mem.writeInt(u16, buffer[index..][0..2], 16, .big); // TXT
    std.mem.writeInt(u16, buffer[index + 2 ..][0..2], 1, .big); // IN
    return buffer[0 .. index + 4];
}

fn parseResponse(
    allocator: std.mem.Allocator,
    packet: []const u8,
    expected_id: u16,
    expected_question: []const u8,
    limits: dns.Limits,
) dns.Error!dns.Response {
    if (packet.len < 12 or packet.len > max_dns_packet_bytes) return error.InvalidResponse;
    if (std.mem.readInt(u16, packet[0..2], .big) != expected_id) return error.InvalidResponse;
    const flags = std.mem.readInt(u16, packet[2..4], .big);
    if ((flags & 0x8000) == 0 or (flags & 0x7800) != 0 or (flags & 0x0200) != 0) {
        return error.InvalidResponse;
    }
    const rcode = flags & 0x000f;
    if (rcode == 3) return dns.Response.initCopy(allocator, &.{}, limits);
    if (rcode != 0) return error.DnsFailed;
    if (std.mem.readInt(u16, packet[4..6], .big) != 1) return error.InvalidResponse;

    var index: usize = 12;
    const question_start = index;
    try skipName(packet, &index);
    if (index + 4 > packet.len) return error.InvalidResponse;
    index += 4;
    if (!std.mem.eql(u8, packet[question_start..index], expected_question)) return error.InvalidResponse;

    const answer_count = std.mem.readInt(u16, packet[6..8], .big);
    var record_buffers: [max_native_records][max_native_record_bytes]u8 = undefined;
    var record_slices: [max_native_records][]const u8 = undefined;
    var record_count: usize = 0;
    var total: usize = 0;
    var answer_index: usize = 0;
    while (answer_index < answer_count) : (answer_index += 1) {
        try skipName(packet, &index);
        if (index + 10 > packet.len) return error.InvalidResponse;
        const record_type = std.mem.readInt(u16, packet[index..][0..2], .big);
        const class = std.mem.readInt(u16, packet[index + 2 ..][0..2], .big);
        const data_len = std.mem.readInt(u16, packet[index + 8 ..][0..2], .big);
        index += 10;
        if (index + data_len > packet.len) return error.InvalidResponse;
        defer index += data_len;
        if (record_type != 16 or class != 1) continue;
        if (record_count >= limits.max_records or record_count >= max_native_records) return error.TooManyRecords;

        const destination = &record_buffers[record_count];
        var source_index = index;
        var output_len: usize = 0;
        const data_end = index + data_len;
        while (source_index < data_end) {
            const chunk_len = packet[source_index];
            source_index += 1;
            if (source_index + chunk_len > data_end) return error.InvalidResponse;
            if (output_len + chunk_len > limits.max_record_bytes or output_len + chunk_len > destination.len) {
                return error.ResponseTooLarge;
            }
            @memcpy(destination[output_len..][0..chunk_len], packet[source_index..][0..chunk_len]);
            output_len += chunk_len;
            source_index += chunk_len;
        }
        total = std.math.add(usize, total, output_len) catch return error.ResponseTooLarge;
        if (total > limits.max_total_bytes) return error.ResponseTooLarge;
        record_slices[record_count] = destination[0..output_len];
        record_count += 1;
    }
    return dns.Response.initCopy(allocator, record_slices[0..record_count], limits);
}

fn skipName(packet: []const u8, index: *usize) dns.Error!void {
    var labels: usize = 0;
    while (true) {
        if (index.* >= packet.len) return error.InvalidResponse;
        const length = packet[index.*];
        if ((length & 0xc0) == 0xc0) {
            if (index.* + 2 > packet.len) return error.InvalidResponse;
            const pointer = (@as(usize, length & 0x3f) << 8) | packet[index.* + 1];
            if (pointer >= packet.len) return error.InvalidResponse;
            index.* += 2;
            return;
        }
        if ((length & 0xc0) != 0 or length > 63) return error.InvalidResponse;
        index.* += 1;
        if (length == 0) return;
        if (index.* + length > packet.len) return error.InvalidResponse;
        index.* += length;
        labels += 1;
        if (labels > 127) return error.InvalidResponse;
    }
}

test "DNS wire parser validates question and concatenates TXT chunks" {
    var query_buffer: [512]u8 = undefined;
    const query = try buildQuery(&query_buffer, 0x1234, "_atproto.alice.example.com");
    var packet: [512]u8 = undefined;
    @memcpy(packet[0..query.len], query);
    std.mem.writeInt(u16, packet[2..4], 0x8180, .big);
    std.mem.writeInt(u16, packet[6..8], 1, .big);
    var index = query.len;
    packet[index] = 0xc0;
    packet[index + 1] = 0x0c;
    index += 2;
    std.mem.writeInt(u16, packet[index..][0..2], 16, .big);
    std.mem.writeInt(u16, packet[index + 2 ..][0..2], 1, .big);
    std.mem.writeInt(u32, packet[index + 4 ..][0..4], 60, .big);
    const first = "did=did:plc:";
    const second = "ewvi7nxzyoun6zhxrhs64oiz";
    const data_len = 1 + first.len + 1 + second.len;
    std.mem.writeInt(u16, packet[index + 8 ..][0..2], @intCast(data_len), .big);
    index += 10;
    packet[index] = @intCast(first.len);
    index += 1;
    @memcpy(packet[index..][0..first.len], first);
    index += first.len;
    packet[index] = @intCast(second.len);
    index += 1;
    @memcpy(packet[index..][0..second.len], second);
    index += second.len;

    var response = try parseResponse(std.testing.allocator, packet[0..index], 0x1234, query[12..], .{});
    defer response.deinit();
    try std.testing.expectEqual(@as(usize, 1), response.records.len);
    try std.testing.expectEqualStrings("did=did:plc:ewvi7nxzyoun6zhxrhs64oiz", response.records[0]);
}

test "DNS wire parser rejects spoofed IDs, truncated packets, and malformed TXT chunks" {
    var query_buffer: [512]u8 = undefined;
    const query = try buildQuery(&query_buffer, 7, "_atproto.alice.example.com");
    var response = query_buffer;
    std.mem.writeInt(u16, response[2..4], 0x8380, .big);
    try std.testing.expectError(error.InvalidResponse, parseResponse(
        std.testing.allocator,
        response[0..query.len],
        7,
        query[12..],
        .{},
    ));
    std.mem.writeInt(u16, response[2..4], 0x8180, .big);
    try std.testing.expectError(error.InvalidResponse, parseResponse(
        std.testing.allocator,
        response[0..query.len],
        8,
        query[12..],
        .{},
    ));

    var malformed = response;
    std.mem.writeInt(u16, malformed[0..2], 7, .big);
    std.mem.writeInt(u16, malformed[6..8], 1, .big);
    var index = query.len;
    malformed[index] = 0xc0;
    malformed[index + 1] = 0x0c;
    index += 2;
    std.mem.writeInt(u16, malformed[index..][0..2], 16, .big);
    std.mem.writeInt(u16, malformed[index + 2 ..][0..2], 1, .big);
    std.mem.writeInt(u32, malformed[index + 4 ..][0..4], 0, .big);
    std.mem.writeInt(u16, malformed[index + 8 ..][0..2], 2, .big);
    index += 10;
    malformed[index] = 5;
    malformed[index + 1] = 'x';
    index += 2;
    try std.testing.expectError(error.InvalidResponse, parseResponse(
        std.testing.allocator,
        malformed[0..index],
        7,
        query[12..],
        .{},
    ));
}

test "native DNS adapter initializes without process or subprocess state" {
    var adapter = try StdDns.init(std.testing.io);
    _ = adapter.client();
}
