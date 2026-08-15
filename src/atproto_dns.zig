//! Portable, bounded DNS TXT capability for AT Protocol handle resolution.
//!
//! This module owns no sockets, resolver configuration, clocks, files, or
//! randomness. A native adapter or deterministic test double supplies those
//! effects. TXT character-string chunks are already concatenated when they
//! cross this boundary.

const std = @import("std");

pub const max_name_bytes = 253;

pub const Error = std.mem.Allocator.Error || error{
    DnsFailed,
    InvalidResponse,
    ResponseTooLarge,
    Timeout,
    TooManyRecords,
    UnexpectedQuery,
};

pub const Limits = struct {
    max_records: usize = 16,
    max_record_bytes: usize = 2048,
    max_total_bytes: usize = 8 * 1024,
    timeout_ms: u32 = 5_000,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    records: [][]u8,

    pub fn initCopy(
        allocator: std.mem.Allocator,
        records: []const []const u8,
        limits: Limits,
    ) Error!Response {
        if (records.len > limits.max_records) return error.TooManyRecords;
        var total: usize = 0;
        const owned = try allocator.alloc([]u8, records.len);
        var initialized: usize = 0;
        errdefer {
            for (owned[0..initialized]) |record| allocator.free(record);
            allocator.free(owned);
        }
        for (records, 0..) |record, index| {
            if (record.len > limits.max_record_bytes) return error.ResponseTooLarge;
            total = std.math.add(usize, total, record.len) catch return error.ResponseTooLarge;
            if (total > limits.max_total_bytes) return error.ResponseTooLarge;
            owned[index] = try allocator.dupe(u8, record);
            initialized += 1;
        }
        return .{ .allocator = allocator, .records = owned };
    }

    pub fn deinit(response: *Response) void {
        for (response.records) |record| response.allocator.free(record);
        response.allocator.free(response.records);
        response.* = undefined;
    }
};

pub const Client = struct {
    context: *anyopaque,
    query_txt_fn: *const fn (*anyopaque, std.mem.Allocator, []const u8, Limits) Error!Response,

    pub fn queryTxt(
        client: Client,
        allocator: std.mem.Allocator,
        name: []const u8,
        limits: Limits,
    ) Error!Response {
        try validateQueryName(name);
        return client.query_txt_fn(client.context, allocator, name, limits);
    }
};

pub const ScriptedMock = struct {
    pub const Outcome = union(enum) {
        records: []const []const u8,
        failure: Error,
    };

    pub const Step = struct {
        expected_name: []const u8,
        outcome: Outcome,
    };

    steps: []const Step,
    next: usize = 0,

    pub fn client(mock: *ScriptedMock) Client {
        return .{ .context = mock, .query_txt_fn = perform };
    }

    pub fn finished(mock: ScriptedMock) bool {
        return mock.next == mock.steps.len;
    }

    fn perform(
        context: *anyopaque,
        allocator: std.mem.Allocator,
        name: []const u8,
        limits: Limits,
    ) Error!Response {
        const mock: *ScriptedMock = @ptrCast(@alignCast(context));
        if (mock.next >= mock.steps.len) return error.UnexpectedQuery;
        const step = mock.steps[mock.next];
        mock.next += 1;
        if (!std.mem.eql(u8, step.expected_name, name)) return error.UnexpectedQuery;
        return switch (step.outcome) {
            .failure => |failure| failure,
            .records => |records| Response.initCopy(allocator, records, limits),
        };
    }
};

pub fn validateQueryName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_bytes or name[name.len - 1] == '.') {
        return error.UnexpectedQuery;
    }
    var labels = std.mem.splitScalar(u8, name, '.');
    while (labels.next()) |label| {
        if (label.len == 0 or label.len > 63) return error.UnexpectedQuery;
        for (label) |byte| {
            if (!std.ascii.isAlphanumeric(byte) and byte != '-' and byte != '_') {
                return error.UnexpectedQuery;
            }
        }
    }
}

test "scripted TXT capability is exact and bounded" {
    const records = [_][]const u8{"did=did:plc:ewvi7nxzyoun6zhxrhs64oiz"};
    const steps = [_]ScriptedMock.Step{.{
        .expected_name = "_atproto.alice.example.com",
        .outcome = .{ .records = &records },
    }};
    var mock: ScriptedMock = .{ .steps = &steps };
    var response = try mock.client().queryTxt(
        std.testing.allocator,
        "_atproto.alice.example.com",
        .{},
    );
    defer response.deinit();
    try std.testing.expectEqualStrings(records[0], response.records[0]);
    try std.testing.expect(mock.finished());
}

test "TXT capability rejects hostile query and response shapes" {
    try std.testing.expectError(error.UnexpectedQuery, validateQueryName("_atproto.bad name.example.com"));
    try std.testing.expectError(error.UnexpectedQuery, validateQueryName(".example.com"));
    try std.testing.expectError(error.ResponseTooLarge, Response.initCopy(
        std.testing.allocator,
        &.{"oversized"},
        .{ .max_record_bytes = 4 },
    ));
    try std.testing.expectError(error.TooManyRecords, Response.initCopy(
        std.testing.allocator,
        &.{ "one", "two" },
        .{ .max_records = 1 },
    ));
}
