const std = @import("std");

pub fn jsonTokenText(token: std.json.Token) ?[]const u8 {
    return switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        .number => |value| value,
        .allocated_number => |value| value,
        else => null,
    };
}

pub fn freeJsonToken(gpa: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |value| gpa.free(value),
        .allocated_number => |value| gpa.free(value),
        else => {},
    }
}

pub fn nextJsonToken(comptime E: type, reader: *std.json.Reader, fail_error: E) E!std.json.Token {
    return reader.next() catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail_error,
    };
}

pub fn nextJsonAllocToken(
    comptime E: type,
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    max_value_len: usize,
    fail_error: E,
) E!std.json.Token {
    return reader.nextAllocMax(gpa, .alloc_if_needed, max_value_len) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => fail_error,
    };
}

pub fn readJsonString(comptime E: type, gpa: std.mem.Allocator, reader: *std.json.Reader, fail_error: E) E![]u8 {
    const token = reader.nextAllocMax(gpa, .alloc_always, 4 * 1024 * 1024) catch |err| {
        return switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            else => fail_error,
        };
    };
    switch (token) {
        .allocated_string => |value| return value,
        .string => |value| return gpa.dupe(u8, value) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
        },
        else => {
            freeJsonToken(gpa, token);
            return fail_error;
        },
    }
}

pub fn readJsonInteger(comptime E: type, gpa: std.mem.Allocator, reader: *std.json.Reader, fail_error: E) E!u64 {
    const token = try nextJsonAllocToken(E, gpa, reader, 64, fail_error);
    defer freeJsonToken(gpa, token);
    const value = jsonTokenText(token) orelse return fail_error;
    return std.fmt.parseInt(u64, value, 10) catch return fail_error;
}

pub fn readJsonBool(comptime E: type, reader: *std.json.Reader, fail_error: E) E!bool {
    return switch (try nextJsonToken(E, reader, fail_error)) {
        .true => true,
        .false => false,
        else => fail_error,
    };
}

pub fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

pub fn readJsonDigest(comptime E: type, gpa: std.mem.Allocator, reader: *std.json.Reader, fail_error: E) E![64]u8 {
    const value = try readJsonString(E, gpa, reader, fail_error);
    defer gpa.free(value);
    if (!validDigest(value)) return fail_error;
    var digest: [64]u8 = undefined;
    @memcpy(&digest, value);
    return digest;
}

pub fn readStringArray(comptime E: type, gpa: std.mem.Allocator, reader: *std.json.Reader, fail_error: E) E![][]const u8 {
    switch (try nextJsonToken(E, reader, fail_error)) {
        .array_begin => {},
        else => return fail_error,
    }
    var values: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (values.items) |value| gpa.free(value);
        values.deinit(gpa);
    }
    while (true) {
        const token = try nextJsonToken(E, reader, fail_error);
        defer freeJsonToken(gpa, token);
        switch (token) {
            .array_end => break,
            .string, .allocated_string => {},
            else => return fail_error,
        }
        const value = jsonTokenText(token) orelse return fail_error;
        try values.append(gpa, try gpa.dupe(u8, value));
    }
    return values.toOwnedSlice(gpa);
}

pub fn containsString(values: []const []const u8, wanted: []const u8) bool {
    for (values) |value| if (std.mem.eql(u8, value, wanted)) return true;
    return false;
}

pub fn knownStatus(value: []const u8) bool {
    return containsString(&.{ "committed", "omitted-by-plan", "not-applicable" }, value);
}

pub fn knownKind(value: []const u8) bool {
    return containsString(
        &.{ "html-page", "theme-asset", "content-asset", "rendered-search", "sitemap", "rss", "llms" },
        value,
    );
}

pub fn knownCheckStatus(value: []const u8) bool {
    return containsString(&.{ "passed", "failed", "incomplete", "not-applicable" }, value);
}

pub fn knownCoverage(value: []const u8) bool {
    return containsString(&.{ "complete", "incomplete", "not-applicable" }, value);
}

pub fn knownFindingCode(value: []const u8) bool {
    return containsString(
        &.{
            "ARTIFACT_MISSING",         "ARTIFACT_SIZE_MISMATCH",  "ARTIFACT_DIGEST_MISMATCH",
            "HTML_PAGE_MISSING",        "HTML_MALFORMED",          "HTML_URL_MALFORMED",
            "HTML_LOCAL_ROUTE_MISSING", "HTML_LOCAL_ROUTE_ESCAPE", "HTML_FRAGMENT_MISSING",
            "HTML_DUPLICATE_ID",        "SEARCH_MISSING",          "SEARCH_MALFORMED",
            "SEARCH_DOCUMENT_MISSING",  "SEARCH_DOCUMENT_STALE",   "SEARCH_CONTENT_MISMATCH",
        },
        value,
    );
}

pub fn knownSeverity(value: []const u8) bool {
    return containsString(&.{ "error", "warning", "info" }, value);
}

pub fn skipJsonValue(comptime E: type, reader: *std.json.Reader, fail_error: E) E!void {
    const first = try nextJsonToken(E, reader, fail_error);
    switch (first) {
        .object_begin, .array_begin => {
            var depth: usize = 1;
            while (depth > 0) {
                const token = try nextJsonToken(E, reader, fail_error);
                switch (token) {
                    .object_begin, .array_begin => depth += 1,
                    .object_end, .array_end => depth -= 1,
                    .end_of_document => return fail_error,
                    else => {},
                }
            }
        },
        .partial_string,
        .partial_string_escaped_1,
        .partial_string_escaped_2,
        .partial_string_escaped_3,
        .partial_string_escaped_4,
        .partial_number,
        => {
            while (true) {
                const token = try nextJsonToken(E, reader, fail_error);
                switch (token) {
                    .partial_string,
                    .partial_string_escaped_1,
                    .partial_string_escaped_2,
                    .partial_string_escaped_3,
                    .partial_string_escaped_4,
                    .partial_number,
                    => {},
                    .string, .number => break,
                    else => return fail_error,
                }
            }
        },
        .string, .number, .true, .false, .null => {},
        .object_end, .array_end, .end_of_document => return fail_error,
        else => return fail_error,
    }
}
