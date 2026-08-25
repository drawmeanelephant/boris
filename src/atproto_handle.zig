//! Portable AT Protocol handle resolution and bidirectional verification.
//!
//! DNS TXT and HTTPS are injected capabilities. This module applies the
//! resolution preference, bounded redirect policy, DID parsing, and the
//! mandatory DID-document `alsoKnownAs` backlink before continuing through
//! the existing DID-to-OAuth-authority chain.

const std = @import("std");
const dns = @import("atproto_dns.zig");
const identity = @import("atproto_identity.zig");
const transport = @import("atproto_transport.zig");

pub const max_dns_handle_bytes = dns.max_name_bytes - "_atproto.".len;
pub const max_https_body_bytes = 4 * 1024;
pub const max_redirects = 3;
pub const max_trimmed_whitespace_bytes = 32;

pub const https_limits: transport.Limits = .{ .max_body_bytes = max_https_body_bytes };
pub const dns_limits: dns.Limits = .{};

pub const Error = identity.Error || dns.Error || error{
    AmbiguousHandle,
    InvalidHandleResolution,
    RedirectLoop,
};

pub const ResolutionMethod = enum { dns_txt, https_well_known };

pub const ResolvedHandle = struct {
    handle: identity.Handle,
    did: identity.Did,
    method: ResolutionMethod,
};

/// Resolves and verifies one user-supplied handle, then reuses the existing
/// immutable DID -> PDS -> Resource Server -> Authorization Server chain.
pub fn discover(
    allocator: std.mem.Allocator,
    dns_client: dns.Client,
    http_client: transport.Client,
    configured_handle: []const u8,
) Error!identity.DiscoveredAccount {
    const resolved = try resolve(allocator, dns_client, http_client, configured_handle);
    const document = try identity.resolveDidDocument(allocator, http_client, resolved.did);
    return identity.discoverResolvedDocument(allocator, http_client, document, resolved.handle);
}

pub fn resolve(
    allocator: std.mem.Allocator,
    dns_client: dns.Client,
    http_client: transport.Client,
    configured_handle: []const u8,
) Error!ResolvedHandle {
    const handle = try identity.Handle.parse(configured_handle);
    try handle.requireResolutionAllowed();

    if (handle.slice().len <= max_dns_handle_bytes) {
        var name_buffer: [dns.max_name_bytes]u8 = undefined;
        const query_name = std.fmt.bufPrint(&name_buffer, "_atproto.{s}", .{handle.slice()}) catch unreachable;
        var response = dns_client.queryTxt(allocator, query_name, dns_limits) catch |err| switch (err) {
            error.DnsFailed, error.Timeout => null,
            else => return err,
        };
        if (response) |*records| {
            defer records.deinit();
            if (try didFromTxtRecords(records.records)) |did| {
                return .{ .handle = handle, .did = did, .method = .dns_txt };
            }
        }
    }

    return .{
        .handle = handle,
        .did = try resolveHttps(allocator, http_client, try handle.httpsResolutionUrl()),
        .method = .https_well_known,
    };
}

fn didFromTxtRecords(records: []const []const u8) Error!?identity.Did {
    var candidate: ?identity.Did = null;
    for (records) |record| {
        if (!std.mem.startsWith(u8, record, "did=")) continue;
        const parsed = identity.Did.parse(record["did=".len..]) catch return error.InvalidHandleResolution;
        if (candidate) |current| {
            if (!std.mem.eql(u8, current.slice(), parsed.slice())) return error.AmbiguousHandle;
        } else {
            candidate = parsed;
        }
    }
    return candidate;
}

fn resolveHttps(
    allocator: std.mem.Allocator,
    client: transport.Client,
    initial: identity.Endpoint,
) Error!identity.Did {
    var visited: [max_redirects + 1]identity.Endpoint = undefined;
    var visited_len: usize = 0;
    var current = initial;

    while (true) {
        for (visited[0..visited_len]) |prior| {
            if (std.mem.eql(u8, prior.slice(), current.slice())) return error.RedirectLoop;
        }
        visited[visited_len] = current;
        visited_len += 1;

        var response = try client.request(allocator, .{
            .url = current.slice(),
            .headers = &.{.{ .name = "accept", .value = "text/plain" }},
            .redirect_policy = .manual_https,
            .limits = https_limits,
        });
        defer response.deinit();

        if (response.status >= 200 and response.status < 300) {
            return parseHttpsBody(response.body);
        }
        if (response.status < 300 or response.status >= 400) return error.UnexpectedStatus;
        if (visited_len > max_redirects) return error.RedirectRejected;
        const location = uniqueHeader(response, "location") orelse return error.RedirectRejected;
        current = try resolveRedirect(current, location);
    }
}

fn parseHttpsBody(body: []const u8) Error!identity.Did {
    const trimmed = std.mem.trim(u8, body, " \t\r\n");
    if (body.len - trimmed.len > max_trimmed_whitespace_bytes or trimmed.len == 0) {
        return error.InvalidHandleResolution;
    }
    return identity.Did.parse(trimmed) catch return error.InvalidHandleResolution;
}

fn resolveRedirect(current: identity.Endpoint, location: []const u8) Error!identity.Endpoint {
    if (std.mem.startsWith(u8, location, "https://")) {
        const endpoint = try identity.Endpoint.parse(location);
        try requireDefaultHttpsPort(endpoint);
        return endpoint;
    }
    if (location.len == 0 or location[0] != '/' or std.mem.startsWith(u8, location, "//")) {
        return error.RedirectRejected;
    }
    const current_text = current.slice();
    const authority_end = std.mem.indexOfAnyPos(u8, current_text, "https://".len, "/?") orelse current_text.len;
    var buffer: [identity.max_endpoint_bytes]u8 = undefined;
    const absolute = std.fmt.bufPrint(&buffer, "{s}{s}", .{ current_text[0..authority_end], location }) catch {
        return error.RedirectRejected;
    };
    return identity.Endpoint.parse(absolute) catch error.RedirectRejected;
}

fn requireDefaultHttpsPort(endpoint: identity.Endpoint) Error!void {
    const text = endpoint.slice();
    const authority_end = std.mem.indexOfAnyPos(u8, text, "https://".len, "/?") orelse text.len;
    if (std.mem.indexOfScalar(u8, text["https://".len..authority_end], ':') != null) {
        return error.RedirectRejected;
    }
}

fn uniqueHeader(response: transport.Response, name: []const u8) ?[]const u8 {
    var result: ?[]const u8 = null;
    for (response.headers) |header| {
        if (!std.ascii.eqlIgnoreCase(header.name, name)) continue;
        if (result != null) return null;
        result = header.value;
    }
    return result;
}

const valid_did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const json_header = [_]transport.Header{.{ .name = "content-type", .value = "application/json" }};
const did_document =
    \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","alsoKnownAs":["https://ignored.example.com","at://alice.example.com","at://later.example.com"],"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
;
const resource_metadata =
    \\{"resource":"https://pds.example.com","authorization_servers":["https://auth.example.com"]}
;
const authorization_metadata =
    \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","pushed_authorization_request_endpoint":"https://auth.example.com/par","scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none","private_key_jwt"],"token_endpoint_auth_signing_alg_values_supported":["ES256"],"dpop_signing_alg_values_supported":["ES256"],"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":true,"client_id_metadata_document_supported":true}
;

fn authoritySteps() [3]transport.ScriptedMock.Step {
    return .{
        .{ .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = did_document } } },
        .{ .expected_url = "https://pds.example.com/.well-known/oauth-protected-resource", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = resource_metadata } } },
        .{ .expected_url = "https://auth.example.com/.well-known/oauth-authorization-server", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = authorization_metadata } } },
    };
}

test "handle syntax normalizes case and separates production restrictions" {
    const handle = try identity.Handle.parse("Alice.Example.COM");
    try std.testing.expectEqualStrings("alice.example.com", handle.slice());
    try handle.requireResolutionAllowed();
    _ = try identity.Handle.parse("xn--bcher-kva.tld");
    _ = try identity.Handle.parse("laptop.local");
    try std.testing.expectError(error.InvalidHandle, (try identity.Handle.parse("laptop.local")).requireResolutionAllowed());
    try std.testing.expectError(error.InvalidHandle, identity.Handle.parse("@alice.example.com"));
    try std.testing.expectError(error.InvalidHandle, identity.Handle.parse("john..example.com"));
    try std.testing.expectError(error.InvalidHandle, identity.Handle.parse("127.0.0.1"));

    inline for (.{
        "A.ISI.EDU",
        "8.cn",
        "0john.example.com",
        "john.t--t",
        "xn--bcher-kva.tld",
        "120.0.0.1.com",
    }) |valid| _ = try identity.Handle.parse(valid);
    inline for (.{
        "did:thing.example.com",
        "john-.example.com",
        "john.0",
        "xn--bcher-.tld",
        "jo_hn.example.com",
        "-john.example.com",
        "john.example.com.",
        "john💩.example.com",
        "org",
        "fe80::1",
    }) |invalid| try std.testing.expectError(error.InvalidHandle, identity.Handle.parse(invalid));
}

test "DNS TXT is preferred and the verified handle enters the authority chain" {
    const records = [_][]const u8{ "unrelated=value", "did=" ++ valid_did };
    const dns_steps = [_]dns.ScriptedMock.Step{.{
        .expected_name = "_atproto.alice.example.com",
        .outcome = .{ .records = &records },
    }};
    var dns_mock: dns.ScriptedMock = .{ .steps = &dns_steps };
    const http_steps = authoritySteps();
    var http_mock: transport.ScriptedMock = .{ .steps = &http_steps };

    const account = try discover(
        std.testing.allocator,
        dns_mock.client(),
        http_mock.client(),
        "Alice.Example.COM",
    );
    try std.testing.expectEqualStrings(valid_did, account.did.slice());
    try std.testing.expectEqualStrings("alice.example.com", account.verified_handle.?.slice());
    try std.testing.expect(dns_mock.finished());
    try std.testing.expect(http_mock.finished());
}

test "DNS absence falls back to HTTPS with bounded relative redirect" {
    const dns_steps = [_]dns.ScriptedMock.Step{.{
        .expected_name = "_atproto.alice.example.com",
        .outcome = .{ .records = &.{} },
    }};
    var dns_mock: dns.ScriptedMock = .{ .steps = &dns_steps };
    const text_headers = [_]transport.Header{.{ .name = "content-type", .value = "text/plain" }};
    const http_steps = [_]transport.ScriptedMock.Step{
        .{
            .expected_url = "https://alice.example.com/.well-known/atproto-did",
            .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
            .expected_redirect_policy = .manual_https,
            .outcome = .{ .response = .{ .status = 302, .headers = &.{.{ .name = "location", .value = "/identity" }}, .body = "" } },
        },
        .{
            .expected_url = "https://alice.example.com/identity",
            .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
            .expected_redirect_policy = .manual_https,
            .outcome = .{ .response = .{ .status = 200, .headers = &text_headers, .body = " \r\n" ++ valid_did ++ "\n" } },
        },
    };
    var http_mock: transport.ScriptedMock = .{ .steps = &http_steps };
    const resolved = try resolve(std.testing.allocator, dns_mock.client(), http_mock.client(), "alice.example.com");
    try std.testing.expectEqual(ResolutionMethod.https_well_known, resolved.method);
    try std.testing.expectEqualStrings(valid_did, resolved.did.slice());
    try std.testing.expect(http_mock.finished());
}

test "conflicting DNS DIDs and malformed authoritative values fail closed" {
    const other_did = "did:plc:aaaaaaaaaaaaaaaaaaaaaaaa";
    const conflict = [_][]const u8{ "did=" ++ valid_did, "did=" ++ other_did };
    try std.testing.expectError(error.AmbiguousHandle, didFromTxtRecords(&conflict));
    try std.testing.expectError(error.InvalidHandleResolution, didFromTxtRecords(&.{"did=not-a-did"}));
    const repeated = try didFromTxtRecords(&.{ "did=" ++ valid_did, "did=" ++ valid_did });
    try std.testing.expectEqualStrings(valid_did, repeated.?.slice());
}

test "HTTPS redirect policy rejects downgrade, loops, and excess hops" {
    const no_dns = [_]dns.ScriptedMock.Step{.{
        .expected_name = "_atproto.alice.example.com",
        .outcome = .{ .failure = error.DnsFailed },
    }};
    var dns_downgrade: dns.ScriptedMock = .{ .steps = &no_dns };
    const downgrade_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://alice.example.com/.well-known/atproto-did",
        .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .expected_redirect_policy = .manual_https,
        .outcome = .{ .response = .{ .status = 302, .headers = &.{.{ .name = "location", .value = "http://127.0.0.1/did" }}, .body = "" } },
    }};
    var downgrade: transport.ScriptedMock = .{ .steps = &downgrade_steps };
    try std.testing.expectError(error.RedirectRejected, resolve(
        std.testing.allocator,
        dns_downgrade.client(),
        downgrade.client(),
        "alice.example.com",
    ));

    var dns_loop: dns.ScriptedMock = .{ .steps = &no_dns };
    const loop_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://alice.example.com/.well-known/atproto-did",
        .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .expected_redirect_policy = .manual_https,
        .outcome = .{ .response = .{ .status = 301, .headers = &.{.{ .name = "location", .value = "/.well-known/atproto-did" }}, .body = "" } },
    }};
    var loop: transport.ScriptedMock = .{ .steps = &loop_steps };
    try std.testing.expectError(error.RedirectLoop, resolve(
        std.testing.allocator,
        dns_loop.client(),
        loop.client(),
        "alice.example.com",
    ));

    var dns_excess: dns.ScriptedMock = .{ .steps = &no_dns };
    const redirect_headers = [_]transport.Header{.{ .name = "location", .value = "/one" }};
    const excess_steps = [_]transport.ScriptedMock.Step{
        .{ .expected_url = "https://alice.example.com/.well-known/atproto-did", .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }}, .expected_redirect_policy = .manual_https, .outcome = .{ .response = .{ .status = 302, .headers = &redirect_headers, .body = "" } } },
        .{ .expected_url = "https://alice.example.com/one", .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }}, .expected_redirect_policy = .manual_https, .outcome = .{ .response = .{ .status = 302, .headers = &.{.{ .name = "location", .value = "/two" }}, .body = "" } } },
        .{ .expected_url = "https://alice.example.com/two", .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }}, .expected_redirect_policy = .manual_https, .outcome = .{ .response = .{ .status = 302, .headers = &.{.{ .name = "location", .value = "/three" }}, .body = "" } } },
        .{ .expected_url = "https://alice.example.com/three", .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }}, .expected_redirect_policy = .manual_https, .outcome = .{ .response = .{ .status = 302, .headers = &.{.{ .name = "location", .value = "/four" }}, .body = "" } } },
    };
    var excess: transport.ScriptedMock = .{ .steps = &excess_steps };
    try std.testing.expectError(error.RedirectRejected, resolve(
        std.testing.allocator,
        dns_excess.client(),
        excess.client(),
        "alice.example.com",
    ));
    try std.testing.expectEqual(@as(usize, 4), excess.next);
}

test "HTTPS redirects may change public origin but never use a non-default port" {
    const no_dns = [_]dns.ScriptedMock.Step{.{
        .expected_name = "_atproto.alice.example.com",
        .outcome = .{ .failure = error.Timeout },
    }};
    var dns_public: dns.ScriptedMock = .{ .steps = &no_dns };
    const steps = [_]transport.ScriptedMock.Step{
        .{ .expected_url = "https://alice.example.com/.well-known/atproto-did", .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }}, .expected_redirect_policy = .manual_https, .outcome = .{ .response = .{ .status = 307, .headers = &.{.{ .name = "location", .value = "https://identity.example.net/atproto/did" }}, .body = "" } } },
        .{ .expected_url = "https://identity.example.net/atproto/did", .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }}, .expected_redirect_policy = .manual_https, .outcome = .{ .response = .{ .status = 200, .headers = &.{}, .body = valid_did } } },
    };
    var public_redirect: transport.ScriptedMock = .{ .steps = &steps };
    const resolved = try resolve(std.testing.allocator, dns_public.client(), public_redirect.client(), "alice.example.com");
    try std.testing.expectEqualStrings(valid_did, resolved.did.slice());

    var dns_port: dns.ScriptedMock = .{ .steps = &no_dns };
    const port_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://alice.example.com/.well-known/atproto-did",
        .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .expected_redirect_policy = .manual_https,
        .outcome = .{ .response = .{ .status = 302, .headers = &.{.{ .name = "location", .value = "https://identity.example.net:8443/did" }}, .body = "" } },
    }};
    var port_redirect: transport.ScriptedMock = .{ .steps = &port_steps };
    try std.testing.expectError(error.RedirectRejected, resolve(
        std.testing.allocator,
        dns_port.client(),
        port_redirect.client(),
        "alice.example.com",
    ));
}

test "HTTPS body parsing is bounded and strips only small ASCII edge whitespace" {
    try std.testing.expectEqualStrings(valid_did, (try parseHttpsBody("\t" ++ valid_did ++ "\r\n")).slice());
    var padding: [max_trimmed_whitespace_bytes + 1 + valid_did.len]u8 = undefined;
    @memset(padding[0 .. max_trimmed_whitespace_bytes + 1], ' ');
    @memcpy(padding[max_trimmed_whitespace_bytes + 1 ..], valid_did);
    try std.testing.expectError(error.InvalidHandleResolution, parseHttpsBody(&padding));
    try std.testing.expectError(error.InvalidHandleResolution, parseHttpsBody("did:key:unsupported"));
}

test "handles too long for the prefixed DNS name use HTTPS directly" {
    var handle_buffer: [247]u8 = undefined;
    var index: usize = 0;
    for (0..4) |_| {
        @memset(handle_buffer[index..][0..60], 'a');
        index += 60;
        handle_buffer[index] = '.';
        index += 1;
    }
    @memcpy(handle_buffer[index..], "com");
    var dns_mock: dns.ScriptedMock = .{ .steps = &.{} };
    var url_buffer: [identity.max_endpoint_bytes]u8 = undefined;
    const expected_url = try std.fmt.bufPrint(
        &url_buffer,
        "https://{s}/.well-known/atproto-did",
        .{&handle_buffer},
    );
    const steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = expected_url,
        .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .expected_redirect_policy = .manual_https,
        .outcome = .{ .response = .{ .status = 200, .headers = &.{}, .body = valid_did } },
    }};
    var http_mock: transport.ScriptedMock = .{ .steps = &steps };
    const resolved = try resolve(std.testing.allocator, dns_mock.client(), http_mock.client(), &handle_buffer);
    try std.testing.expectEqual(ResolutionMethod.https_well_known, resolved.method);
    try std.testing.expectEqual(@as(usize, 0), dns_mock.next);
}

test "HTTPS fallback rejects oversized bodies and ambiguous Location headers" {
    const no_dns = [_]dns.ScriptedMock.Step{.{
        .expected_name = "_atproto.alice.example.com",
        .outcome = .{ .failure = error.DnsFailed },
    }};
    const oversized_body: [max_https_body_bytes + 1]u8 = @splat('x');
    var dns_oversized: dns.ScriptedMock = .{ .steps = &no_dns };
    const oversized_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://alice.example.com/.well-known/atproto-did",
        .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .expected_redirect_policy = .manual_https,
        .outcome = .{ .response = .{ .status = 200, .headers = &.{}, .body = &oversized_body } },
    }};
    var oversized: transport.ScriptedMock = .{ .steps = &oversized_steps };
    try std.testing.expectError(error.ResponseTooLarge, resolve(
        std.testing.allocator,
        dns_oversized.client(),
        oversized.client(),
        "alice.example.com",
    ));

    var dns_ambiguous: dns.ScriptedMock = .{ .steps = &no_dns };
    const ambiguous_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://alice.example.com/.well-known/atproto-did",
        .expected_headers = &.{.{ .name = "accept", .value = "text/plain" }},
        .expected_redirect_policy = .manual_https,
        .outcome = .{ .response = .{
            .status = 302,
            .headers = &.{
                .{ .name = "location", .value = "/one" },
                .{ .name = "Location", .value = "/two" },
            },
            .body = "",
        } },
    }};
    var ambiguous: transport.ScriptedMock = .{ .steps = &ambiguous_steps };
    try std.testing.expectError(error.RedirectRejected, resolve(
        std.testing.allocator,
        dns_ambiguous.client(),
        ambiguous.client(),
        "alice.example.com",
    ));
}

test "DID backlink is mandatory and first syntactically valid handle wins" {
    const did = try identity.Did.parse(valid_did);
    const mismatch =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","alsoKnownAs":["at://wrong.example.com","at://alice.example.com"],"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
    ;
    const document = try identity.validateDidDocument(std.testing.allocator, did, mismatch);
    try std.testing.expectEqualStrings("wrong.example.com", document.claimed_handle.?.slice());
    try std.testing.expectError(error.HandleMismatch, identity.discoverResolvedDocument(
        std.testing.allocator,
        undefinedTransportClient(),
        document,
        try identity.Handle.parse("alice.example.com"),
    ));

    const missing =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","alsoKnownAs":["https://alice.example.com"],"service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
    ;
    const missing_document = try identity.validateDidDocument(std.testing.allocator, did, missing);
    try std.testing.expect(missing_document.claimed_handle == null);
    try std.testing.expectError(error.HandleMismatch, identity.discoverResolvedDocument(
        std.testing.allocator,
        undefinedTransportClient(),
        missing_document,
        try identity.Handle.parse("alice.example.com"),
    ));
}

fn undefinedTransportClient() transport.Client {
    return .{ .context = undefined, .request_fn = unreachableRequest };
}

fn unreachableRequest(_: *anyopaque, _: std.mem.Allocator, _: transport.Request) transport.Error!transport.Response {
    return error.UnexpectedRequest;
}
