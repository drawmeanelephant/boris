//! Portable AT Protocol DID resolution and OAuth authority discovery.
//!
//! JSON parsing, URL validation, and chain binding live here. Network effects
//! are injected through `atproto_transport.Client`; this module does not own
//! sockets, DNS, redirects, clocks, files, or process state.

const std = @import("std");
const transport = @import("atproto_transport.zig");

pub const max_did_bytes = 2048;
pub const max_handle_bytes = 253;
pub const max_origin_bytes = 512;
pub const max_endpoint_bytes = transport.max_url_bytes;
pub const max_json_nesting = 16;
pub const max_json_value_bytes = 16 * 1024;

pub const did_document_limits: transport.Limits = .{ .max_body_bytes = 256 * 1024 };
pub const resource_metadata_limits: transport.Limits = .{ .max_body_bytes = 64 * 1024 };
pub const authorization_metadata_limits: transport.Limits = .{ .max_body_bytes = 64 * 1024 };

pub const Error = transport.Error || std.mem.Allocator.Error || error{
    AmbiguousMetadata,
    DidDocumentIdMismatch,
    InvalidAuthorizationMetadata,
    InvalidContentType,
    InvalidDid,
    InvalidEndpoint,
    InvalidHandle,
    InvalidIssuer,
    InvalidOrigin,
    InvalidPdsService,
    InvalidResourceMetadata,
    JsonTooDeep,
    MalformedJson,
    MissingPdsService,
    HandleMismatch,
    UnsupportedDidMethod,
    UnexpectedStatus,
};

pub const DidMethod = enum { plc, web };

pub const Did = struct {
    bytes: [max_did_bytes]u8 = undefined,
    len: u16,
    method: DidMethod,

    pub fn parse(input: []const u8) Error!Did {
        if (input.len == 0 or input.len > max_did_bytes) return error.InvalidDid;
        for (input) |byte| {
            if (byte <= 0x20 or byte >= 0x7f) return error.InvalidDid;
        }

        if (!std.mem.startsWith(u8, input, "did:")) return error.InvalidDid;
        const method_start = "did:".len;
        const method_end = std.mem.indexOfScalarPos(u8, input, method_start, ':') orelse return error.InvalidDid;
        const method_text = input[method_start..method_end];
        if (method_text.len == 0) return error.InvalidDid;
        for (method_text) |byte| if (!std.ascii.isLower(byte)) return error.InvalidDid;
        const method: DidMethod = if (std.mem.eql(u8, method_text, "plc"))
            .plc
        else if (std.mem.eql(u8, method_text, "web"))
            .web
        else
            return error.UnsupportedDidMethod;
        const identifier = input[method_end + 1 ..];

        switch (method) {
            .plc => try validatePlcIdentifier(identifier),
            .web => try validateWebIdentifier(identifier),
        }

        var result: Did = .{ .len = @intCast(input.len), .method = method };
        @memcpy(result.bytes[0..input.len], input);
        return result;
    }

    pub fn slice(did: *const Did) []const u8 {
        return did.bytes[0..did.len];
    }

    pub fn resolutionUrl(did: *const Did) Error!Endpoint {
        var buffer: [max_endpoint_bytes]u8 = undefined;
        const url = switch (did.method) {
            .plc => std.fmt.bufPrint(&buffer, "https://plc.directory/{s}", .{did.slice()}) catch return error.InvalidEndpoint,
            .web => std.fmt.bufPrint(&buffer, "https://{s}/.well-known/did.json", .{did.slice()["did:web:".len..]}) catch return error.InvalidEndpoint,
        };
        return Endpoint.parse(url);
    }
};

/// Normalized ATProto handle syntax. Parsing is deliberately distinct from
/// production resolution policy: reserved names remain syntactically valid,
/// but `requireResolutionAllowed` rejects them before network use.
pub const Handle = struct {
    bytes: [max_handle_bytes]u8 = undefined,
    len: u8,

    pub fn parse(input: []const u8) Error!Handle {
        if (input.len == 0 or input.len > max_handle_bytes) return error.InvalidHandle;
        var result: Handle = .{ .len = @intCast(input.len) };
        for (input, 0..) |byte, index| {
            if (byte >= 0x80) return error.InvalidHandle;
            result.bytes[index] = std.ascii.toLower(byte);
        }
        const normalized = result.slice();
        if (std.mem.indexOfScalar(u8, normalized, '.') == null or normalized[0] == '.' or normalized[normalized.len - 1] == '.') {
            return error.InvalidHandle;
        }
        var labels = std.mem.splitScalar(u8, normalized, '.');
        var last: []const u8 = undefined;
        while (labels.next()) |label| {
            if (label.len == 0 or label.len > 63 or label[0] == '-' or label[label.len - 1] == '-') {
                return error.InvalidHandle;
            }
            for (label) |byte| {
                if (!std.ascii.isAlphanumeric(byte) and byte != '-') return error.InvalidHandle;
            }
            last = label;
        }
        if (!std.ascii.isAlphabetic(last[0])) return error.InvalidHandle;
        return result;
    }

    pub fn slice(handle: *const Handle) []const u8 {
        return handle.bytes[0..handle.len];
    }

    pub fn eql(a: *const Handle, b: *const Handle) bool {
        return std.mem.eql(u8, a.slice(), b.slice());
    }

    pub fn requireResolutionAllowed(handle: *const Handle) Error!void {
        const text = handle.slice();
        const tld = text[(std.mem.lastIndexOfScalar(u8, text, '.') orelse unreachable) + 1 ..];
        inline for (.{ "alt", "arpa", "example", "internal", "invalid", "local", "localhost", "onion", "test" }) |blocked| {
            if (std.mem.eql(u8, tld, blocked)) return error.InvalidHandle;
        }
    }

    pub fn httpsResolutionUrl(handle: *const Handle) Error!Endpoint {
        var buffer: [max_endpoint_bytes]u8 = undefined;
        const url = std.fmt.bufPrint(
            &buffer,
            "https://{s}/.well-known/atproto-did",
            .{handle.slice()},
        ) catch return error.InvalidEndpoint;
        return Endpoint.parse(url);
    }
};

pub const Origin = struct {
    bytes: [max_origin_bytes]u8 = undefined,
    len: u16,

    pub fn parse(input: []const u8) Error!Origin {
        _ = try parseHttpsUrl(input, true);
        if (input.len > max_origin_bytes) return error.InvalidOrigin;
        var result: Origin = .{ .len = @intCast(input.len) };
        @memcpy(result.bytes[0..input.len], input);
        return result;
    }

    pub fn slice(origin: *const Origin) []const u8 {
        return origin.bytes[0..origin.len];
    }

    pub fn wellKnown(origin: *const Origin, suffix: []const u8) Error!Endpoint {
        var buffer: [max_endpoint_bytes]u8 = undefined;
        const url = std.fmt.bufPrint(&buffer, "{s}/.well-known/{s}", .{ origin.slice(), suffix }) catch return error.InvalidEndpoint;
        return Endpoint.parse(url);
    }
};

pub const Endpoint = struct {
    bytes: [max_endpoint_bytes]u8 = undefined,
    len: u16,

    pub fn parse(input: []const u8) Error!Endpoint {
        _ = try parseHttpsUrl(input, false);
        if (input.len > max_endpoint_bytes) return error.InvalidEndpoint;
        var result: Endpoint = .{ .len = @intCast(input.len) };
        @memcpy(result.bytes[0..input.len], input);
        return result;
    }

    pub fn slice(endpoint: *const Endpoint) []const u8 {
        return endpoint.bytes[0..endpoint.len];
    }
};

pub const ResourceServerMetadata = struct {
    resource: Origin,
    authorization_server: Origin,
};

pub const AuthorizationServerMetadata = struct {
    issuer: Origin,
    authorization_endpoint: Endpoint,
    token_endpoint: Endpoint,
    pushed_authorization_request_endpoint: Endpoint,
};

pub const DidDocument = struct {
    did: Did,
    pds_origin: Origin,
    /// First syntactically valid `at://handle` entry, per the ordered ATProto
    /// DID-document rule. Presence alone is not authentication.
    claimed_handle: ?Handle,
};

pub const DiscoveredAccount = struct {
    did: Did,
    verified_handle: ?Handle,
    pds_origin: Origin,
    authorization_server_origin: Origin,
    authorization_endpoint: Endpoint,
    token_endpoint: Endpoint,
    pushed_authorization_request_endpoint: Endpoint,
};

pub fn discover(allocator: std.mem.Allocator, client: transport.Client, configured_did: []const u8) Error!DiscoveredAccount {
    const did = try Did.parse(configured_did);
    const document = try resolveDidDocument(allocator, client, did);
    return discoverResolvedDocument(allocator, client, document, null);
}

pub fn resolveDidDocument(
    allocator: std.mem.Allocator,
    client: transport.Client,
    did: Did,
) Error!DidDocument {
    const did_url = try did.resolutionUrl();
    var did_response = try getJson(allocator, client, did_url, did_document_limits, true);
    defer did_response.deinit();
    return validateDidDocument(allocator, did, did_response.body);
}

/// Require the DID document to name `handle` in `alsoKnownAs`. Used by the
/// OAuth discovery chain and by the app-password login path, which stops at
/// the DID document and must not skip the backlink.
pub fn requireHandleBacklink(document: DidDocument, handle: Handle) Error!void {
    try handle.requireResolutionAllowed();
    const claimed = document.claimed_handle orelse return error.HandleMismatch;
    if (!handle.eql(&claimed)) return error.HandleMismatch;
}

/// Continues authority discovery from one already-resolved DID document. This
/// avoids a second DID fetch between handle verification and OAuth binding.
pub fn discoverResolvedDocument(
    allocator: std.mem.Allocator,
    client: transport.Client,
    document: DidDocument,
    verified_handle: ?Handle,
) Error!DiscoveredAccount {
    if (verified_handle) |handle| try requireHandleBacklink(document, handle);
    const pds = document.pds_origin;

    const resource_url = try pds.wellKnown("oauth-protected-resource");
    var resource_response = try getJson(allocator, client, resource_url, resource_metadata_limits, false);
    defer resource_response.deinit();
    const resource = try validateResourceMetadata(allocator, pds, resource_response.body);

    const authorization_url = try resource.authorization_server.wellKnown("oauth-authorization-server");
    var authorization_response = try getJson(allocator, client, authorization_url, authorization_metadata_limits, false);
    defer authorization_response.deinit();
    const authorization = try validateAuthorizationMetadata(
        allocator,
        resource.authorization_server,
        authorization_response.body,
    );

    return .{
        .did = document.did,
        .verified_handle = verified_handle,
        .pds_origin = pds,
        .authorization_server_origin = authorization.issuer,
        .authorization_endpoint = authorization.authorization_endpoint,
        .token_endpoint = authorization.token_endpoint,
        .pushed_authorization_request_endpoint = authorization.pushed_authorization_request_endpoint,
    };
}

pub fn validateDidDocument(allocator: std.mem.Allocator, expected: Did, body: []const u8) Error!DidDocument {
    try validateJsonEnvelope(body);
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .max_value_len = max_json_value_bytes,
    }) catch return error.MalformedJson;
    defer parsed.deinit();

    const document = switch (parsed.value) {
        .object => |object| object,
        else => return error.MalformedJson,
    };
    const document_id = jsonString(document.get("id") orelse return error.MalformedJson) orelse return error.MalformedJson;
    if (!std.mem.eql(u8, document_id, expected.slice())) return error.DidDocumentIdMismatch;
    const claimed_handle = parseClaimedHandle(document.get("alsoKnownAs"));
    const services = switch (document.get("service") orelse return error.MissingPdsService) {
        .array => |array| array,
        else => return error.InvalidPdsService,
    };
    if (services.items.len > 64) return error.InvalidPdsService;
    for (services.items) |service_value| {
        const service = switch (service_value) {
            .object => |object| object,
            else => continue,
        };
        const service_id = jsonString(service.get("id") orelse continue) orelse continue;
        const service_type = jsonString(service.get("type") orelse continue) orelse continue;
        if (!isPdsServiceId(service_id, expected.slice()) or
            !std.mem.eql(u8, service_type, "AtprotoPersonalDataServer")) continue;
        const endpoint = jsonString(service.get("serviceEndpoint") orelse return error.InvalidPdsService) orelse return error.InvalidPdsService;
        const pds_origin = Origin.parse(endpoint) catch return error.InvalidPdsService;
        return .{ .did = expected, .pds_origin = pds_origin, .claimed_handle = claimed_handle };
    }
    return error.MissingPdsService;
}

fn parseClaimedHandle(value: ?std.json.Value) ?Handle {
    const aliases = switch (value orelse return null) {
        .array => |array| array,
        else => return null,
    };
    for (aliases.items) |alias_value| {
        const alias = jsonString(alias_value) orelse continue;
        if (!std.mem.startsWith(u8, alias, "at://")) continue;
        const handle = Handle.parse(alias["at://".len..]) catch continue;
        return handle;
    }
    return null;
}

pub fn validateResourceMetadata(
    allocator: std.mem.Allocator,
    expected_resource: Origin,
    body: []const u8,
) Error!ResourceServerMetadata {
    try validateJsonEnvelope(body);
    const Wire = struct {
        resource: []const u8,
        authorization_servers: []const []const u8,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = max_json_value_bytes,
    }) catch return error.MalformedJson;
    defer parsed.deinit();

    if (!std.mem.eql(u8, parsed.value.resource, expected_resource.slice())) return error.InvalidResourceMetadata;
    if (parsed.value.authorization_servers.len != 1) return error.AmbiguousMetadata;
    const authorization_server = Origin.parse(parsed.value.authorization_servers[0]) catch return error.InvalidResourceMetadata;
    return .{ .resource = expected_resource, .authorization_server = authorization_server };
}

pub fn validateAuthorizationMetadata(
    allocator: std.mem.Allocator,
    expected_issuer: Origin,
    body: []const u8,
) Error!AuthorizationServerMetadata {
    try validateJsonEnvelope(body);
    const Wire = struct {
        issuer: []const u8,
        authorization_endpoint: []const u8,
        token_endpoint: []const u8,
        pushed_authorization_request_endpoint: []const u8,
        scopes_supported: []const []const u8,
        response_types_supported: []const []const u8,
        grant_types_supported: []const []const u8,
        code_challenge_methods_supported: []const []const u8,
        token_endpoint_auth_methods_supported: []const []const u8,
        token_endpoint_auth_signing_alg_values_supported: []const []const u8,
        dpop_signing_alg_values_supported: []const []const u8,
        authorization_response_iss_parameter_supported: bool,
        require_pushed_authorization_requests: bool,
        client_id_metadata_document_supported: bool,
        require_request_uri_registration: bool = true,
    };
    var parsed = std.json.parseFromSlice(Wire, allocator, body, .{
        .ignore_unknown_fields = true,
        .max_value_len = max_json_value_bytes,
    }) catch return error.MalformedJson;
    defer parsed.deinit();
    const value = parsed.value;

    if (!std.mem.eql(u8, value.issuer, expected_issuer.slice())) return error.InvalidIssuer;
    inline for (.{
        value.scopes_supported,
        value.response_types_supported,
        value.grant_types_supported,
        value.code_challenge_methods_supported,
        value.token_endpoint_auth_methods_supported,
        value.token_endpoint_auth_signing_alg_values_supported,
        value.dpop_signing_alg_values_supported,
    }) |list| if (list.len > 64) return error.InvalidAuthorizationMetadata;

    if (!contains(value.scopes_supported, "atproto") or
        !contains(value.response_types_supported, "code") or
        !contains(value.grant_types_supported, "authorization_code") or
        !contains(value.grant_types_supported, "refresh_token") or
        !contains(value.code_challenge_methods_supported, "S256") or
        !contains(value.token_endpoint_auth_methods_supported, "none") or
        !contains(value.token_endpoint_auth_methods_supported, "private_key_jwt") or
        !contains(value.token_endpoint_auth_signing_alg_values_supported, "ES256") or
        contains(value.token_endpoint_auth_signing_alg_values_supported, "none") or
        !contains(value.dpop_signing_alg_values_supported, "ES256") or
        !value.authorization_response_iss_parameter_supported or
        !value.require_pushed_authorization_requests or
        !value.client_id_metadata_document_supported or
        !value.require_request_uri_registration)
    {
        return error.InvalidAuthorizationMetadata;
    }

    return .{
        .issuer = expected_issuer,
        .authorization_endpoint = Endpoint.parse(value.authorization_endpoint) catch return error.InvalidEndpoint,
        .token_endpoint = Endpoint.parse(value.token_endpoint) catch return error.InvalidEndpoint,
        .pushed_authorization_request_endpoint = Endpoint.parse(value.pushed_authorization_request_endpoint) catch return error.InvalidEndpoint,
    };
}

const ParsedHttps = struct { host: []const u8, port: ?u16 };

fn parseHttpsUrl(input: []const u8, origin_only: bool) Error!ParsedHttps {
    if (input.len == 0 or input.len > max_endpoint_bytes or !std.mem.startsWith(u8, input, "https://")) {
        return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
    }
    for (input) |byte| {
        if (byte <= 0x20 or byte >= 0x7f or byte == '\\') return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
    }
    if (std.mem.indexOfScalar(u8, input, '#') != null) return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;

    const authority_start = "https://".len;
    const authority_end = std.mem.indexOfAnyPos(u8, input, authority_start, "/?") orelse input.len;
    const authority = input[authority_start..authority_end];
    if (authority.len == 0 or std.mem.indexOfAny(u8, authority, "@[]%") != null) {
        return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
    }

    var host = authority;
    var port: ?u16 = null;
    if (std.mem.lastIndexOfScalar(u8, authority, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, authority[0..colon], ':') != null) return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
        host = authority[0..colon];
        if (authority[colon + 1 ..].len == 0) return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
        const port_text = authority[colon + 1 ..];
        if (port_text.len > 1 and port_text[0] == '0') return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
        port = std.fmt.parseInt(u16, port_text, 10) catch return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
        if (port.? == 0 or port.? == 443) return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;
    }
    validateProductionHost(host) catch return if (origin_only) error.InvalidOrigin else error.InvalidEndpoint;

    const remainder = input[authority_end..];
    if (origin_only and remainder.len != 0) return error.InvalidOrigin;
    if (!origin_only) try validateEndpointRemainder(remainder);
    return .{ .host = host, .port = port };
}

fn validateEndpointRemainder(remainder: []const u8) Error!void {
    var index: usize = 0;
    while (index < remainder.len) : (index += 1) {
        if (remainder[index] != '%') continue;
        if (index + 2 >= remainder.len or !std.ascii.isHex(remainder[index + 1]) or !std.ascii.isHex(remainder[index + 2])) return error.InvalidEndpoint;
        const escaped = std.fmt.parseInt(u8, remainder[index + 1 ..][0..2], 16) catch return error.InvalidEndpoint;
        if (escaped == '.' or escaped == '/' or escaped == '\\') return error.InvalidEndpoint;
        index += 2;
    }
    const path_end = std.mem.indexOfScalar(u8, remainder, '?') orelse remainder.len;
    var segments = std.mem.splitScalar(u8, remainder[0..path_end], '/');
    while (segments.next()) |segment| {
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return error.InvalidEndpoint;
    }
}

fn validateProductionHost(host: []const u8) Error!void {
    if (host.len == 0 or host.len > 253 or host[host.len - 1] == '.') return error.InvalidOrigin;
    if (std.mem.indexOfScalar(u8, host, '.') == null) return error.InvalidOrigin;
    for (host) |byte| if (std.ascii.isUpper(byte)) return error.InvalidOrigin;
    std.Io.net.HostName.validate(host) catch return error.InvalidOrigin;

    const tld = host[(std.mem.lastIndexOfScalar(u8, host, '.') orelse unreachable) + 1 ..];
    if (!std.ascii.isAlphabetic(tld[0])) return error.InvalidOrigin;
    inline for (.{ "alt", "arpa", "example", "internal", "invalid", "local", "localhost", "onion", "test" }) |blocked| {
        if (std.mem.eql(u8, tld, blocked)) return error.InvalidOrigin;
    }
}

fn validatePlcIdentifier(identifier: []const u8) Error!void {
    if (identifier.len != 24) return error.InvalidDid;
    for (identifier) |byte| {
        if (!std.ascii.isLower(byte) and !(byte >= '2' and byte <= '7')) return error.InvalidDid;
    }
}

fn validateWebIdentifier(identifier: []const u8) Error!void {
    if (std.mem.indexOfAny(u8, identifier, ":/%?#@\\") != null) return error.InvalidDid;
    validateProductionHost(identifier) catch return error.InvalidDid;
}

fn isPdsServiceId(service_id: []const u8, did: []const u8) bool {
    if (std.mem.eql(u8, service_id, "#atproto_pds")) return true;
    if (service_id.len != did.len + "#atproto_pds".len) return false;
    return std.mem.startsWith(u8, service_id, did) and std.mem.endsWith(u8, service_id, "#atproto_pds");
}

fn contains(values: []const []const u8, expected: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, expected)) return true;
    return false;
}

fn jsonString(value: std.json.Value) ?[]const u8 {
    return switch (value) {
        .string => |string| string,
        else => null,
    };
}

fn getJson(
    allocator: std.mem.Allocator,
    client: transport.Client,
    endpoint: Endpoint,
    limits: transport.Limits,
    allow_did_json: bool,
) Error!transport.Response {
    var response = try client.request(allocator, .{ .url = endpoint.slice(), .limits = limits });
    errdefer response.deinit();
    if (response.status >= 300 and response.status < 400) return error.RedirectRejected;
    if (response.status != 200) return error.UnexpectedStatus;
    const content_type = uniqueHeader(response, "content-type") orelse return error.InvalidContentType;
    if (!isJsonContentType(content_type, allow_did_json)) return error.InvalidContentType;
    return response;
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

fn isJsonContentType(value: []const u8, allow_did_json: bool) bool {
    const separator = std.mem.indexOfScalar(u8, value, ';') orelse value.len;
    const media_type = std.mem.trim(u8, value[0..separator], " \t");
    return std.ascii.eqlIgnoreCase(media_type, "application/json") or
        (allow_did_json and std.ascii.eqlIgnoreCase(media_type, "application/did+ld+json"));
}

fn validateJsonEnvelope(body: []const u8) Error!void {
    var depth: usize = 0;
    var in_string = false;
    var escaped = false;
    for (body) |byte| {
        if (in_string) {
            if (escaped) {
                escaped = false;
            } else if (byte == '\\') {
                escaped = true;
            } else if (byte == '"') {
                in_string = false;
            }
            continue;
        }
        switch (byte) {
            '"' => in_string = true,
            '{', '[' => {
                depth += 1;
                if (depth > max_json_nesting) return error.JsonTooDeep;
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
            },
            else => {},
        }
    }
    if (in_string or depth != 0) return error.MalformedJson;
}

const valid_did = "did:plc:ewvi7nxzyoun6zhxrhs64oiz";
const valid_as_metadata =
    \\{
    \\  "issuer":"https://auth.example.com",
    \\  "authorization_endpoint":"https://auth.example.com/authorize",
    \\  "token_endpoint":"https://auth.example.com/token",
    \\  "pushed_authorization_request_endpoint":"https://auth.example.com/par",
    \\  "scopes_supported":["atproto"],
    \\  "response_types_supported":["code"],
    \\  "grant_types_supported":["authorization_code","refresh_token"],
    \\  "code_challenge_methods_supported":["S256"],
    \\  "token_endpoint_auth_methods_supported":["none","private_key_jwt"],
    \\  "token_endpoint_auth_signing_alg_values_supported":["ES256"],
    \\  "dpop_signing_alg_values_supported":["ES256"],
    \\  "authorization_response_iss_parameter_supported":true,
    \\  "require_pushed_authorization_requests":true,
    \\  "client_id_metadata_document_supported":true
    \\}
;

test "strict DID parsing supports only production did:plc and host-level did:web" {
    const plc = try Did.parse(valid_did);
    try std.testing.expectEqual(DidMethod.plc, plc.method);
    try std.testing.expectEqualStrings(valid_did, plc.slice());
    const web = try Did.parse("did:web:user.example.com");
    try std.testing.expectEqual(DidMethod.web, web.method);
    const web_url = try web.resolutionUrl();
    try std.testing.expectEqualStrings("https://user.example.com/.well-known/did.json", web_url.slice());

    try std.testing.expectError(error.UnsupportedDidMethod, Did.parse("did:key:z6Mkfoo"));
    try std.testing.expectError(error.InvalidDid, Did.parse("did:PLC:ewvi7nxzyoun6zhxrhs64oiz"));
    try std.testing.expectError(error.InvalidDid, Did.parse("did:plc"));
    try std.testing.expectError(error.InvalidDid, Did.parse(" did:plc:ewvi7nxzyoun6zhxrhs64oiz"));
    try std.testing.expectError(error.InvalidDid, Did.parse("did:web:user.example.com:path"));
    try std.testing.expectError(error.InvalidDid, Did.parse("did:web:localhost"));
    try std.testing.expectError(error.InvalidDid, Did.parse("did:web:127.0.0.1"));
}

test "DID document validates identity and first matching PDS service" {
    const did = try Did.parse(valid_did);
    const relative =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","alsoKnownAs":["at://untrusted.example.com"],"service":[
        \\{"id":"#other","type":"Other","serviceEndpoint":"https://ignored.example.com"},
        \\{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"},
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://second.example.com"}
        \\]}
    ;
    const document = try validateDidDocument(std.testing.allocator, did, relative);
    try std.testing.expectEqualStrings("https://pds.example.com", document.pds_origin.slice());
    try std.testing.expectEqualStrings("untrusted.example.com", document.claimed_handle.?.slice());

    try std.testing.expectError(error.DidDocumentIdMismatch, validateDidDocument(
        std.testing.allocator,
        did,
        "{\"id\":\"did:plc:aaaaaaaaaaaaaaaaaaaaaaaa\",\"service\":[]}",
    ));
    try std.testing.expectError(error.MissingPdsService, validateDidDocument(
        std.testing.allocator,
        did,
        "{\"id\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"service\":[]}",
    ));

    const fully_qualified =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[
        \\{"id":"#unrelated","type":["Unexpected","Shape"]},
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://qualified.example.com"}
        \\]}
    ;
    const qualified_document = try validateDidDocument(std.testing.allocator, did, fully_qualified);
    try std.testing.expectEqualStrings("https://qualified.example.com", qualified_document.pds_origin.slice());
    try std.testing.expectError(error.InvalidPdsService, validateDidDocument(
        std.testing.allocator,
        did,
        "{\"id\":\"did:plc:ewvi7nxzyoun6zhxrhs64oiz\",\"service\":[{\"id\":\"#atproto_pds\",\"type\":\"AtprotoPersonalDataServer\",\"serviceEndpoint\":\"https://pds.example.com/path\"}]}",
    ));
}

test "requireHandleBacklink demands the DID document alsoKnownAs match" {
    const did = try Did.parse(valid_did);
    const matching =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","alsoKnownAs":["at://alice.example.com"],"service":[
        \\{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}
        \\]}
    ;
    const document = try validateDidDocument(std.testing.allocator, did, matching);
    const handle = try Handle.parse("alice.example.com");
    try requireHandleBacklink(document, handle);

    const other = try Handle.parse("other.example.com");
    try std.testing.expectError(error.HandleMismatch, requireHandleBacklink(document, other));

    const no_handle =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[
        \\{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}
        \\]}
    ;
    const bare = try validateDidDocument(std.testing.allocator, did, no_handle);
    try std.testing.expectError(error.HandleMismatch, requireHandleBacklink(bare, handle));
}

test "origin and endpoint validation fail closed" {
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("http://pds.example.com"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://user@pds.example.com"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://pds.example.com/path"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://pds.example.com?x=1"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://pds.example.com#x"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://127.0.0.1"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://router.local"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://pds.example.com:443"));
    try std.testing.expectError(error.InvalidOrigin, Origin.parse("https://pds.example.com:08443"));
    try std.testing.expectError(error.InvalidEndpoint, Endpoint.parse("https://auth.example.com/%2e%2e/token"));
    _ = try Origin.parse("https://pds.example.com:8443");
    _ = try Endpoint.parse("https://auth.example.com/authorize?prompt=login");
}

test "resource and authorization metadata validate mandatory bindings and capabilities" {
    const pds = try Origin.parse("https://pds.example.com");
    const resource = try validateResourceMetadata(
        std.testing.allocator,
        pds,
        "{\"resource\":\"https://pds.example.com\",\"authorization_servers\":[\"https://auth.example.com\"]}",
    );
    try std.testing.expectEqualStrings("https://auth.example.com", resource.authorization_server.slice());
    _ = try validateAuthorizationMetadata(std.testing.allocator, resource.authorization_server, valid_as_metadata);

    try std.testing.expectError(error.InvalidResourceMetadata, validateResourceMetadata(
        std.testing.allocator,
        pds,
        "{\"resource\":\"https://evil.example.com\",\"authorization_servers\":[\"https://auth.example.com\"]}",
    ));
    try std.testing.expectError(error.AmbiguousMetadata, validateResourceMetadata(
        std.testing.allocator,
        pds,
        "{\"resource\":\"https://pds.example.com\",\"authorization_servers\":[]}",
    ));
    try std.testing.expectError(error.AmbiguousMetadata, validateResourceMetadata(
        std.testing.allocator,
        pds,
        "{\"resource\":\"https://pds.example.com\",\"authorization_servers\":[\"https://one.example.com\",\"https://two.example.com\"]}",
    ));
    try std.testing.expectError(error.InvalidResourceMetadata, validateResourceMetadata(
        std.testing.allocator,
        pds,
        "{\"resource\":\"https://pds.example.com\",\"authorization_servers\":[\"http://auth.example.com\"]}",
    ));
    try std.testing.expectError(error.InvalidIssuer, validateAuthorizationMetadata(
        std.testing.allocator,
        try Origin.parse("https://other.example.com"),
        valid_as_metadata,
    ));
}

test "authorization metadata rejects every missing security capability" {
    const issuer = try Origin.parse("https://auth.example.com");
    const missing_token = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_as_metadata,
        "  \"token_endpoint\":\"https://auth.example.com/token\",\n",
        "",
    );
    defer std.testing.allocator.free(missing_token);
    try std.testing.expectError(error.MalformedJson, validateAuthorizationMetadata(std.testing.allocator, issuer, missing_token));

    const plain_pkce = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid_as_metadata,
        "\"code_challenge_methods_supported\":[\"S256\"]",
        "\"code_challenge_methods_supported\":[\"plain\"]",
    );
    defer std.testing.allocator.free(plain_pkce);
    try std.testing.expectError(error.InvalidAuthorizationMetadata, validateAuthorizationMetadata(std.testing.allocator, issuer, plain_pkce));

    const missing_par =
        \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token",
        \\"scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],
        \\"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["none","private_key_jwt"],
        \\"token_endpoint_auth_signing_alg_values_supported":["ES256"],"dpop_signing_alg_values_supported":["ES256"],
        \\"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":true,"client_id_metadata_document_supported":true}
    ;
    try std.testing.expectError(error.MalformedJson, validateAuthorizationMetadata(std.testing.allocator, issuer, missing_par));

    const missing_es256 =
        \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","pushed_authorization_request_endpoint":"https://auth.example.com/par",
        \\"scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],
        \\"token_endpoint_auth_methods_supported":["none","private_key_jwt"],"token_endpoint_auth_signing_alg_values_supported":["RS256"],"dpop_signing_alg_values_supported":["RS256"],
        \\"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":true,"client_id_metadata_document_supported":true}
    ;
    try std.testing.expectError(error.InvalidAuthorizationMetadata, validateAuthorizationMetadata(std.testing.allocator, issuer, missing_es256));

    const weakened =
        \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","pushed_authorization_request_endpoint":"https://auth.example.com/par",
        \\"scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],
        \\"token_endpoint_auth_methods_supported":["none","private_key_jwt"],"token_endpoint_auth_signing_alg_values_supported":["ES256","none"],"dpop_signing_alg_values_supported":["ES256"],
        \\"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":false,"client_id_metadata_document_supported":true,"require_request_uri_registration":false}
    ;
    try std.testing.expectError(error.InvalidAuthorizationMetadata, validateAuthorizationMetadata(std.testing.allocator, issuer, weakened));

    const null_registration =
        \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"https://auth.example.com/token","pushed_authorization_request_endpoint":"https://auth.example.com/par",
        \\"scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],
        \\"token_endpoint_auth_methods_supported":["none","private_key_jwt"],"token_endpoint_auth_signing_alg_values_supported":["ES256"],"dpop_signing_alg_values_supported":["ES256"],
        \\"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":true,"client_id_metadata_document_supported":true,"require_request_uri_registration":null}
    ;
    try std.testing.expectError(error.MalformedJson, validateAuthorizationMetadata(std.testing.allocator, issuer, null_registration));

    const malformed_endpoint =
        \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://auth.example.com/authorize","token_endpoint":"http://127.0.0.1/token","pushed_authorization_request_endpoint":"https://auth.example.com/par",
        \\"scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],
        \\"token_endpoint_auth_methods_supported":["none","private_key_jwt"],"token_endpoint_auth_signing_alg_values_supported":["ES256"],"dpop_signing_alg_values_supported":["ES256"],
        \\"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":true,"client_id_metadata_document_supported":true}
    ;
    try std.testing.expectError(error.InvalidEndpoint, validateAuthorizationMetadata(std.testing.allocator, issuer, malformed_endpoint));
}

test "RFC metadata endpoints may differ in origin while the issuer remains exactly bound" {
    const metadata =
        \\{"issuer":"https://auth.example.com","authorization_endpoint":"https://login.example.com/authorize","token_endpoint":"https://tokens.example.com/token","pushed_authorization_request_endpoint":"https://par.example.com/request",
        \\"scopes_supported":["atproto"],"response_types_supported":["code"],"grant_types_supported":["authorization_code","refresh_token"],"code_challenge_methods_supported":["S256"],
        \\"token_endpoint_auth_methods_supported":["none","private_key_jwt"],"token_endpoint_auth_signing_alg_values_supported":["ES256"],"dpop_signing_alg_values_supported":["ES256"],
        \\"authorization_response_iss_parameter_supported":true,"require_pushed_authorization_requests":true,"client_id_metadata_document_supported":true}
    ;
    const result = try validateAuthorizationMetadata(std.testing.allocator, try Origin.parse("https://auth.example.com"), metadata);
    try std.testing.expectEqualStrings("https://tokens.example.com/token", result.token_endpoint.slice());
}

test "complete DID to OAuth authority chain uses exact URLs and rejects redirects" {
    const did_document =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
    ;
    const resource_metadata =
        \\{"resource":"https://pds.example.com","authorization_servers":["https://auth.example.com"]}
    ;
    const json_header = [_]transport.Header{.{ .name = "content-type", .value = "application/json" }};
    const steps = [_]transport.ScriptedMock.Step{
        .{ .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = did_document } } },
        .{ .expected_url = "https://pds.example.com/.well-known/oauth-protected-resource", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = resource_metadata } } },
        .{ .expected_url = "https://auth.example.com/.well-known/oauth-authorization-server", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = valid_as_metadata } } },
    };
    var mock: transport.ScriptedMock = .{ .steps = &steps };
    const account = try discover(std.testing.allocator, mock.client(), valid_did);
    try std.testing.expectEqualStrings(valid_did, account.did.slice());
    try std.testing.expectEqualStrings("https://pds.example.com", account.pds_origin.slice());
    try std.testing.expectEqualStrings("https://auth.example.com", account.authorization_server_origin.slice());
    try std.testing.expect(mock.finished());

    const redirect_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        .outcome = .{ .response = .{
            .status = 302,
            .headers = &.{.{ .name = "location", .value = "http://127.0.0.1/did" }},
            .body = "",
        } },
    }};
    var redirect_mock: transport.ScriptedMock = .{ .steps = &redirect_steps };
    try std.testing.expectError(error.RedirectRejected, discover(std.testing.allocator, redirect_mock.client(), valid_did));
}

test "host-level did:web follows the same bound discovery chain" {
    const did = "did:web:user.example.com";
    const did_document =
        \\{"id":"did:web:user.example.com","service":[{"id":"did:web:user.example.com#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
    ;
    const resource_metadata =
        \\{"resource":"https://pds.example.com","authorization_servers":["https://auth.example.com"]}
    ;
    const json_header = [_]transport.Header{.{ .name = "content-type", .value = "application/json; charset=utf-8" }};
    const steps = [_]transport.ScriptedMock.Step{
        .{ .expected_url = "https://user.example.com/.well-known/did.json", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = did_document } } },
        .{ .expected_url = "https://pds.example.com/.well-known/oauth-protected-resource", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = resource_metadata } } },
        .{ .expected_url = "https://auth.example.com/.well-known/oauth-authorization-server", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = valid_as_metadata } } },
    };
    var mock: transport.ScriptedMock = .{ .steps = &steps };
    const account = try discover(std.testing.allocator, mock.client(), did);
    try std.testing.expectEqualStrings(did, account.did.slice());
    try std.testing.expect(mock.finished());
}

test "forbidden redirects stop before loops, cross-origin hops, or downgrade targets" {
    const steps = [_]transport.ScriptedMock.Step{
        .{
            .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz",
            .outcome = .{ .response = .{
                .status = 301,
                .headers = &.{.{ .name = "location", .value = "https://loop.example.com/two" }},
                .body = "",
            } },
        },
        .{
            .expected_url = "https://loop.example.com/two",
            .outcome = .{ .response = .{
                .status = 302,
                .headers = &.{.{ .name = "location", .value = "http://127.0.0.1/one" }},
                .body = "",
            } },
        },
    };
    var mock: transport.ScriptedMock = .{ .steps = &steps };
    try std.testing.expectError(error.RedirectRejected, discover(std.testing.allocator, mock.client(), valid_did));
    try std.testing.expectEqual(@as(usize, 1), mock.next);
}

test "authorization metadata substitution cannot escape issuer binding" {
    const did_document =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
    ;
    const substituted_resource =
        \\{"resource":"https://pds.example.com","authorization_servers":["https://evil.example.com"]}
    ;
    const json_header = [_]transport.Header{.{ .name = "content-type", .value = "application/json" }};
    const steps = [_]transport.ScriptedMock.Step{
        .{ .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = did_document } } },
        .{ .expected_url = "https://pds.example.com/.well-known/oauth-protected-resource", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = substituted_resource } } },
        .{ .expected_url = "https://evil.example.com/.well-known/oauth-authorization-server", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = valid_as_metadata } } },
    };
    var mock: transport.ScriptedMock = .{ .steps = &steps };
    try std.testing.expectError(error.InvalidIssuer, discover(std.testing.allocator, mock.client(), valid_did));
    try std.testing.expect(mock.finished());
}

test "network-fed JSON, content types, bodies, and failures stay bounded" {
    const did_document =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://pds.example.com"}]}
    ;
    const bad_type_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        .outcome = .{ .response = .{ .status = 200, .headers = &.{.{ .name = "content-type", .value = "text/html" }}, .body = did_document } },
    }};
    var bad_type: transport.ScriptedMock = .{ .steps = &bad_type_steps };
    try std.testing.expectError(error.InvalidContentType, discover(std.testing.allocator, bad_type.client(), valid_did));

    const timeout_steps = [_]transport.ScriptedMock.Step{.{
        .expected_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz",
        .outcome = .{ .failure = error.Timeout },
    }};
    var timeout: transport.ScriptedMock = .{ .steps = &timeout_steps };
    try std.testing.expectError(error.Timeout, discover(std.testing.allocator, timeout.client(), valid_did));

    var deeply_nested: [max_json_nesting + 2]u8 = undefined;
    @memset(&deeply_nested, '[');
    try std.testing.expectError(error.JsonTooDeep, validateDidDocument(std.testing.allocator, try Did.parse(valid_did), &deeply_nested));
    try std.testing.expectError(error.MalformedJson, validateDidDocument(
        std.testing.allocator,
        try Did.parse(valid_did),
        "{not-json}",
    ));
}

test "discovery has no stale cache across changing identity metadata" {
    const first_did =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://one.example.com"}]}
    ;
    const second_did =
        \\{"id":"did:plc:ewvi7nxzyoun6zhxrhs64oiz","service":[{"id":"#atproto_pds","type":"AtprotoPersonalDataServer","serviceEndpoint":"https://two.example.com"}]}
    ;
    const first_resource = "{\"resource\":\"https://one.example.com\",\"authorization_servers\":[\"https://auth.example.com\"]}";
    const second_resource = "{\"resource\":\"https://two.example.com\",\"authorization_servers\":[\"https://auth.example.com\"]}";
    const json_header = [_]transport.Header{.{ .name = "content-type", .value = "application/json" }};
    const resolve_url = "https://plc.directory/did:plc:ewvi7nxzyoun6zhxrhs64oiz";
    const steps = [_]transport.ScriptedMock.Step{
        .{ .expected_url = resolve_url, .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = first_did } } },
        .{ .expected_url = "https://one.example.com/.well-known/oauth-protected-resource", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = first_resource } } },
        .{ .expected_url = "https://auth.example.com/.well-known/oauth-authorization-server", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = valid_as_metadata } } },
        .{ .expected_url = resolve_url, .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = second_did } } },
        .{ .expected_url = "https://two.example.com/.well-known/oauth-protected-resource", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = second_resource } } },
        .{ .expected_url = "https://auth.example.com/.well-known/oauth-authorization-server", .outcome = .{ .response = .{ .status = 200, .headers = &json_header, .body = valid_as_metadata } } },
    };
    var mock: transport.ScriptedMock = .{ .steps = &steps };
    const first = try discover(std.testing.allocator, mock.client(), valid_did);
    const second = try discover(std.testing.allocator, mock.client(), valid_did);
    try std.testing.expectEqualStrings("https://one.example.com", first.pds_origin.slice());
    try std.testing.expectEqualStrings("https://two.example.com", second.pds_origin.slice());
    try std.testing.expect(mock.finished());
}
