//! Portable, capability-based transport seam for AT Protocol discovery.
//!
//! This module defines no sockets, DNS, clocks, files, proxy lookup, or other
//! host behavior. OAuth asks for bounded GETs or form-encoded POSTs at already
//! validated URLs. A host adapter or deterministic test double supplies the
//! capability; no adapter follows redirects without portable policy code
//! validating the hop.

const std = @import("std");

pub const max_url_bytes = 2048;

pub const Error = std.mem.Allocator.Error || error{
    ConnectFailed,
    DnsFailed,
    HeaderTooLarge,
    InvalidResponse,
    RedirectRejected,
    ResponseTooLarge,
    Timeout,
    TlsFailed,
    TooManyHeaders,
    UnexpectedRequest,
    UnsafeTarget,
};

pub const Method = enum { get, post };
/// Native adapters never redirect implicitly. `manual_https` permits a 3xx
/// response to cross the capability boundary so portable policy code can
/// validate and issue the next HTTPS request itself.
pub const RedirectPolicy = enum { forbid, manual_https };

pub const Header = struct {
    name: []const u8,
    value: []const u8,
};

/// Safety bounds are implementation limits, not AT Protocol wire semantics.
pub const Limits = struct {
    max_body_bytes: usize,
    max_request_body_bytes: usize = 16 * 1024,
    max_header_count: usize = 64,
    max_header_bytes: usize = 16 * 1024,
    max_header_name_bytes: usize = 256,
    max_header_value_bytes: usize = 8 * 1024,
    timeout_ms: u32 = 15_000,
};

pub const Request = struct {
    method: Method = .get,
    url: []const u8,
    headers: []const Header = &.{.{ .name = "accept", .value = "application/json" }},
    body: []const u8 = "",
    redirect_policy: RedirectPolicy = .forbid,
    limits: Limits,
};

pub const Response = struct {
    allocator: std.mem.Allocator,
    status: u16,
    headers: []Header,
    body: []u8,

    pub fn initCopy(
        allocator: std.mem.Allocator,
        status: u16,
        headers: []const Header,
        body: []const u8,
        limits: Limits,
    ) Error!Response {
        try validateResponseShape(headers, body.len, limits);
        const owned_headers = try allocator.alloc(Header, headers.len);
        var initialized: usize = 0;
        errdefer {
            for (owned_headers[0..initialized]) |owned_header| {
                allocator.free(owned_header.name);
                allocator.free(owned_header.value);
            }
            allocator.free(owned_headers);
        }
        for (headers, 0..) |source_header, index| {
            owned_headers[index] = .{
                .name = try allocator.dupe(u8, source_header.name),
                .value = try allocator.dupe(u8, source_header.value),
            };
            initialized += 1;
        }
        const owned_body = try allocator.dupe(u8, body);
        return .{
            .allocator = allocator,
            .status = status,
            .headers = owned_headers,
            .body = owned_body,
        };
    }

    pub fn deinit(response: *Response) void {
        for (response.headers) |owned_header| {
            response.allocator.free(owned_header.name);
            response.allocator.free(owned_header.value);
        }
        response.allocator.free(response.headers);
        response.allocator.free(response.body);
        response.* = undefined;
    }

    pub fn header(response: Response, name: []const u8) ?[]const u8 {
        var found: ?[]const u8 = null;
        for (response.headers) |candidate| {
            if (!std.ascii.eqlIgnoreCase(candidate.name, name)) continue;
            if (found != null) return null;
            found = candidate.value;
        }
        return found;
    }
};

pub const Client = struct {
    context: *anyopaque,
    request_fn: *const fn (*anyopaque, std.mem.Allocator, Request) Error!Response,

    pub fn request(client: Client, allocator: std.mem.Allocator, request_value: Request) Error!Response {
        if (request_value.url.len == 0 or request_value.url.len > max_url_bytes) return error.UnsafeTarget;
        if (request_value.body.len > request_value.limits.max_request_body_bytes) return error.ResponseTooLarge;
        if (request_value.method == .get and request_value.body.len != 0) return error.UnexpectedRequest;
        try validateHeaders(request_value.headers, request_value.limits);
        return client.request_fn(client.context, allocator, request_value);
    }
};

pub const ScriptedMock = struct {
    pub const Outcome = union(enum) {
        response: struct {
            status: u16,
            headers: []const Header,
            body: []const u8,
        },
        failure: Error,
    };

    pub const Step = struct {
        expected_method: Method = .get,
        expected_url: []const u8,
        expected_headers: []const Header = &.{.{ .name = "accept", .value = "application/json" }},
        expected_body: []const u8 = "",
        expected_redirect_policy: RedirectPolicy = .forbid,
        outcome: Outcome,
    };

    steps: []const Step,
    next: usize = 0,

    pub fn client(mock: *ScriptedMock) Client {
        return .{ .context = mock, .request_fn = perform };
    }

    pub fn finished(mock: ScriptedMock) bool {
        return mock.next == mock.steps.len;
    }

    fn perform(context: *anyopaque, allocator: std.mem.Allocator, request_value: Request) Error!Response {
        const mock: *ScriptedMock = @ptrCast(@alignCast(context));
        if (mock.next >= mock.steps.len) return error.UnexpectedRequest;
        const step = mock.steps[mock.next];
        mock.next += 1;
        if (step.expected_method != request_value.method or
            step.expected_redirect_policy != request_value.redirect_policy or
            !std.mem.eql(u8, step.expected_url, request_value.url) or
            !std.mem.eql(u8, step.expected_body, request_value.body) or
            !headersEqual(step.expected_headers, request_value.headers))
        {
            return error.UnexpectedRequest;
        }
        return switch (step.outcome) {
            .failure => |failure| failure,
            .response => |response| Response.initCopy(
                allocator,
                response.status,
                response.headers,
                response.body,
                request_value.limits,
            ),
        };
    }
};

pub fn validateResponseShape(headers: []const Header, body_len: usize, limits: Limits) Error!void {
    if (body_len > limits.max_body_bytes) return error.ResponseTooLarge;
    if (headers.len > limits.max_header_count) return error.TooManyHeaders;
    var total: usize = 0;
    for (headers) |header| {
        if (header.name.len == 0 or header.name.len > limits.max_header_name_bytes) return error.HeaderTooLarge;
        if (header.value.len > limits.max_header_value_bytes) return error.HeaderTooLarge;
        for (header.name) |byte| if (!isHeaderNameByte(byte)) return error.InvalidResponse;
        for (header.value) |byte| if ((byte < 0x20 and byte != '\t') or byte == 0x7f) return error.InvalidResponse;
        total = std.math.add(usize, total, header.name.len + header.value.len) catch return error.HeaderTooLarge;
        if (total > limits.max_header_bytes) return error.HeaderTooLarge;
    }
}

fn validateHeaders(headers: []const Header, limits: Limits) Error!void {
    return validateResponseShape(headers, 0, .{
        .max_body_bytes = 0,
        .max_request_body_bytes = limits.max_request_body_bytes,
        .max_header_count = limits.max_header_count,
        .max_header_bytes = limits.max_header_bytes,
        .max_header_name_bytes = limits.max_header_name_bytes,
        .max_header_value_bytes = limits.max_header_value_bytes,
        .timeout_ms = limits.timeout_ms,
    });
}

fn isHeaderNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or switch (byte) {
        '!', '#', '$', '%', '&', '\'', '*', '+', '-', '.', '^', '_', '`', '|', '~' => true,
        else => false,
    };
}

fn headersEqual(expected: []const Header, actual: []const Header) bool {
    if (expected.len != actual.len) return false;
    for (expected, actual) |a, b| {
        if (!std.ascii.eqlIgnoreCase(a.name, b.name) or !std.mem.eql(u8, a.value, b.value)) return false;
    }
    return true;
}

test "scripted mock checks requests and enforces response limits" {
    const steps = [_]ScriptedMock.Step{.{
        .expected_url = "https://example.com/.well-known/test",
        .outcome = .{ .response = .{
            .status = 200,
            .headers = &.{.{ .name = "content-type", .value = "application/json" }},
            .body = "{}",
        } },
    }};
    var mock: ScriptedMock = .{ .steps = &steps };
    var response = try mock.client().request(std.testing.allocator, .{
        .url = "https://example.com/.well-known/test",
        .limits = .{ .max_body_bytes = 2 },
    });
    defer response.deinit();
    try std.testing.expectEqual(@as(u16, 200), response.status);
    try std.testing.expect(mock.finished());
}

test "scripted mock can inject failures, redirects, and changing responses" {
    const steps = [_]ScriptedMock.Step{
        .{ .expected_url = "https://one.example", .outcome = .{ .failure = error.Timeout } },
        .{ .expected_url = "https://two.example", .outcome = .{ .response = .{
            .status = 302,
            .headers = &.{.{ .name = "location", .value = "https://private.example" }},
            .body = "",
        } } },
    };
    var mock: ScriptedMock = .{ .steps = &steps };
    try std.testing.expectError(error.Timeout, mock.client().request(std.testing.allocator, .{
        .url = "https://one.example",
        .limits = .{ .max_body_bytes = 1 },
    }));
    var redirect = try mock.client().request(std.testing.allocator, .{
        .url = "https://two.example",
        .limits = .{ .max_body_bytes = 1 },
    });
    defer redirect.deinit();
    try std.testing.expectEqual(@as(u16, 302), redirect.status);
    try std.testing.expect(mock.finished());
}

test "hostile response bodies and headers are rejected before copying" {
    try std.testing.expectError(error.ResponseTooLarge, Response.initCopy(
        std.testing.allocator,
        200,
        &.{},
        "too large",
        .{ .max_body_bytes = 4 },
    ));
    try std.testing.expectError(error.TooManyHeaders, Response.initCopy(
        std.testing.allocator,
        200,
        &.{
            .{ .name = "one", .value = "1" },
            .{ .name = "two", .value = "2" },
        },
        "",
        .{ .max_body_bytes = 0, .max_header_count = 1 },
    ));
    try std.testing.expectError(error.HeaderTooLarge, Response.initCopy(
        std.testing.allocator,
        200,
        &.{.{ .name = "x", .value = "oversized" }},
        "",
        .{ .max_body_bytes = 0, .max_header_value_bytes = 4 },
    ));
    try std.testing.expectError(error.InvalidResponse, Response.initCopy(
        std.testing.allocator,
        200,
        &.{.{ .name = "bad header", .value = "value" }},
        "",
        .{ .max_body_bytes = 0 },
    ));
}

test "request bodies are bounded and GET remains bodyless" {
    var mock: ScriptedMock = .{ .steps = &.{} };
    try std.testing.expectError(error.ResponseTooLarge, mock.client().request(std.testing.allocator, .{
        .method = .post,
        .url = "https://example.com/token",
        .body = "oversized",
        .limits = .{ .max_body_bytes = 1, .max_request_body_bytes = 4 },
    }));
    try std.testing.expectError(error.UnexpectedRequest, mock.client().request(std.testing.allocator, .{
        .url = "https://example.com/token",
        .body = "not-empty",
        .limits = .{ .max_body_bytes = 1 },
    }));
}
