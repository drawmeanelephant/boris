//! Small parse helpers extracted from publication_touches for QM-3.
//! Keeps error-set parameterization intact (InvalidChecksReport vs InvalidTouchesReport).

const std = @import("std");
const json_stream = @import("publication_json_stream.zig");

pub fn parseCountsBlock(
    comptime E: type,
    gpa: std.mem.Allocator,
    reader: *std.json.Reader,
    fail_error: E,
) E!struct { eligible: usize, checked: usize, findings: usize } {
    switch (try json_stream.nextJsonToken(E, reader, fail_error)) {
        .object_begin => {},
        else => return fail_error,
    }
    var have_eligible = false;
    var have_checked = false;
    var have_findings = false;
    var eligible: usize = 0;
    var checked: usize = 0;
    var findings: usize = 0;
    while (true) {
        const key_token = try json_stream.nextJsonAllocToken(E, gpa, reader, 4096, fail_error);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer json_stream.freeJsonToken(gpa, key_token);
        const key = json_stream.jsonTokenText(key_token) orelse return fail_error;
        if (std.mem.eql(u8, key, "eligible")) {
            if (have_eligible) return fail_error;
            const v = try json_stream.readJsonInteger(E, gpa, reader, fail_error);
            if (v > std.math.maxInt(usize)) return fail_error;
            eligible = @intCast(v);
            have_eligible = true;
        } else if (std.mem.eql(u8, key, "checked")) {
            if (have_checked) return fail_error;
            const v = try json_stream.readJsonInteger(E, gpa, reader, fail_error);
            if (v > std.math.maxInt(usize)) return fail_error;
            checked = @intCast(v);
            have_checked = true;
        } else if (std.mem.eql(u8, key, "findings")) {
            if (have_findings) return fail_error;
            const v = try json_stream.readJsonInteger(E, gpa, reader, fail_error);
            if (v > std.math.maxInt(usize)) return fail_error;
            findings = @intCast(v);
            have_findings = true;
        } else {
            return fail_error;
        }
    }
    if (!have_eligible or !have_checked or !have_findings) return fail_error;
    return .{ .eligible = eligible, .checked = checked, .findings = findings };
}
