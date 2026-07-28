//! Strict publication policy for content-local SVG assets.
//!
//! SVG is an XML document, not an inert image format. Boris never rewrites an
//! author's asset, so this module recognizes a deliberately small set of
//! executable or document-embedding constructs and lets the caller refuse the
//! file before it reaches `dist/`.

const std = @import("std");

pub const Policy = enum {
    allow,
    refuse_active_content,
};

/// The product default. Flip only with an explicit author-facing policy change.
pub const default_policy: Policy = .refuse_active_content;

pub const Violation = enum {
    script_element,
    foreign_object_element,
    embedded_document_element,
    event_handler_attribute,
    javascript_url,
    document_declaration,

    pub fn description(self: Violation) []const u8 {
        return switch (self) {
            .script_element => "active SVG <script> element",
            .foreign_object_element => "active SVG <foreignObject> element",
            .embedded_document_element => "embedded-document SVG element",
            .event_handler_attribute => "SVG on* event-handler attribute",
            .javascript_url => "SVG javascript: URL",
            .document_declaration => "SVG document or entity declaration",
        };
    }
};

/// Returns the first active construct found in an SVG document.
///
/// This is intentionally a recognizer, not a sanitizer or a general XML
/// parser. It skips XML comments, CDATA, and processing instructions so inert
/// explanatory text does not fail a build; malformed markup remains the web
/// server/browser's XML error, not a reason to mutate the source asset.
pub fn firstViolation(bytes: []const u8) ?Violation {
    var i: usize = 0;
    while (i < bytes.len) {
        const next = std.mem.indexOfScalarPos(u8, bytes, i, '<') orelse break;
        i = next;

        if (startsWithIgnoreCase(bytes[i..], "<!--")) {
            i = afterTerminator(bytes, i + 4, "-->");
            continue;
        }
        if (startsWithIgnoreCase(bytes[i..], "<![CDATA[")) {
            i = afterTerminator(bytes, i + 9, "]]>");
            continue;
        }
        if (startsWithIgnoreCase(bytes[i..], "<?")) {
            i = afterTerminator(bytes, i + 2, "?>");
            continue;
        }
        // A DTD can define entities which hide an active URL or fetch an
        // external resource. SVG does not need one, so refusing all document
        // declarations is clearer and safer than trying to expand XML.
        if (startsWithIgnoreCase(bytes[i..], "<!DOCTYPE") or
            startsWithIgnoreCase(bytes[i..], "<!ENTITY")) return .document_declaration;

        const tag_end = tagEnd(bytes, i + 1) orelse break;
        if (inspectTag(bytes[i + 1 .. tag_end])) |violation| return violation;
        i = tag_end + 1;
    }
    return null;
}

fn startsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return haystack.len >= needle.len and std.ascii.eqlIgnoreCase(haystack[0..needle.len], needle);
}

fn afterTerminator(bytes: []const u8, start: usize, terminator: []const u8) usize {
    const end = std.mem.indexOfPos(u8, bytes, start, terminator) orelse return bytes.len;
    return end + terminator.len;
}

fn tagEnd(bytes: []const u8, start: usize) ?usize {
    var quote: ?u8 = null;
    var i = start;
    while (i < bytes.len) : (i += 1) {
        const c = bytes[i];
        if (quote) |q| {
            if (c == q) quote = null;
            continue;
        }
        if (c == '\'' or c == '"') {
            quote = c;
        } else if (c == '>') {
            return i;
        }
    }
    return null;
}

fn inspectTag(raw: []const u8) ?Violation {
    var i: usize = 0;
    skipSpace(raw, &i);
    if (i >= raw.len or raw[i] == '/' or raw[i] == '!' or raw[i] == '?') return null;

    const element_start = i;
    i = nameEnd(raw, i);
    if (i == element_start) return null;
    const element = localName(raw[element_start..i]);
    if (std.ascii.eqlIgnoreCase(element, "script")) return .script_element;
    if (std.ascii.eqlIgnoreCase(element, "foreignobject")) return .foreign_object_element;
    if (isEmbeddedDocumentElement(element)) return .embedded_document_element;

    while (i < raw.len) {
        skipSpace(raw, &i);
        if (i >= raw.len or raw[i] == '/') break;

        const attr_start = i;
        i = nameEnd(raw, i);
        if (i == attr_start) break;
        const attr = localName(raw[attr_start..i]);
        if (attr.len > 2 and std.ascii.startsWithIgnoreCase(attr, "on")) return .event_handler_attribute;

        skipSpace(raw, &i);
        if (i >= raw.len or raw[i] != '=') continue;
        i += 1;
        skipSpace(raw, &i);
        const value = attributeValue(raw, &i);
        if (isJavascriptUrl(value)) return .javascript_url;
    }
    return null;
}

fn skipSpace(bytes: []const u8, i: *usize) void {
    while (i.* < bytes.len and std.ascii.isWhitespace(bytes[i.*])) i.* += 1;
}

fn nameEnd(bytes: []const u8, start: usize) usize {
    var i = start;
    while (i < bytes.len and !std.ascii.isWhitespace(bytes[i]) and bytes[i] != '=' and bytes[i] != '/' and bytes[i] != '>') : (i += 1) {}
    return i;
}

fn localName(name: []const u8) []const u8 {
    const colon = std.mem.lastIndexOfScalar(u8, name, ':') orelse return name;
    return name[colon + 1 ..];
}

fn isEmbeddedDocumentElement(name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(name, "iframe") or
        std.ascii.eqlIgnoreCase(name, "object") or
        std.ascii.eqlIgnoreCase(name, "embed");
}

fn attributeValue(raw: []const u8, i: *usize) []const u8 {
    if (i.* >= raw.len) return "";
    const start = i.*;
    if (raw[i.*] == '\'' or raw[i.*] == '"') {
        const quote = raw[i.*];
        i.* += 1;
        const value_start = i.*;
        while (i.* < raw.len and raw[i.*] != quote) i.* += 1;
        const value_end = i.*;
        if (i.* < raw.len) i.* += 1;
        return raw[value_start..value_end];
    }
    while (i.* < raw.len and !std.ascii.isWhitespace(raw[i.*]) and raw[i.*] != '/') i.* += 1;
    return raw[start..i.*];
}

/// Recognize `javascript:` after XML numeric character references and ASCII
/// whitespace have been normalized. The DTD refusal above prevents a custom
/// entity from being used to hide this prefix.
fn isJavascriptUrl(value: []const u8) bool {
    const expected = "javascript:";
    var expected_i: usize = 0;
    var value_i: usize = 0;
    while (expected_i < expected.len) {
        const next = nextNormalizedByte(value, value_i) orelse return false;
        value_i = next.next;
        if (std.ascii.isWhitespace(next.byte)) continue;
        if (std.ascii.toLower(next.byte) != expected[expected_i]) return false;
        expected_i += 1;
    }
    return true;
}

const NormalizedByte = struct { byte: u8, next: usize };

fn nextNormalizedByte(value: []const u8, start: usize) ?NormalizedByte {
    if (start >= value.len) return null;
    if (value[start] != '&' or start + 3 >= value.len or value[start + 1] != '#') {
        return .{ .byte = value[start], .next = start + 1 };
    }
    var i = start + 2;
    var radix: u8 = 10;
    if (i < value.len and (value[i] == 'x' or value[i] == 'X')) {
        radix = 16;
        i += 1;
    }
    const digits_start = i;
    var codepoint: u32 = 0;
    while (i < value.len and value[i] != ';') : (i += 1) {
        const digit = std.fmt.charToDigit(value[i], radix) catch return .{ .byte = value[start], .next = start + 1 };
        codepoint = std.math.mul(u32, codepoint, radix) catch return .{ .byte = value[start], .next = start + 1 };
        codepoint = std.math.add(u32, codepoint, digit) catch return .{ .byte = value[start], .next = start + 1 };
    }
    if (i == digits_start or i >= value.len or codepoint > 0xff) return .{ .byte = value[start], .next = start + 1 };
    return .{ .byte = @intCast(codepoint), .next = i + 1 };
}

test "recognizes active SVG constructs" {
    try std.testing.expectEqual(Violation.script_element, firstViolation("<svg><script>alert(1)</script></svg>").?);
    try std.testing.expectEqual(Violation.foreign_object_element, firstViolation("<svg><foreignObject/></svg>").?);
    try std.testing.expectEqual(Violation.embedded_document_element, firstViolation("<svg><iframe src=\"x\"/></svg>").?);
    try std.testing.expectEqual(Violation.event_handler_attribute, firstViolation("<svg onload=\"alert(1)\"/>").?);
    try std.testing.expectEqual(Violation.javascript_url, firstViolation("<svg href=\"java&#x73;cript:alert(1)\"/>").?);
    try std.testing.expectEqual(Violation.document_declaration, firstViolation("<!DOCTYPE svg [<!ENTITY x SYSTEM \"https://example.test/x\">]><svg/>").?);
}

test "permits inert SVG text and ordinary markup" {
    try std.testing.expect(firstViolation("<svg viewBox=\"0 0 1 1\"><path d=\"M0 0\"/></svg>") == null);
    try std.testing.expect(firstViolation("<svg><!-- <script>alert(1)</script> --><![CDATA[<script>example</script>]]></svg>") == null);
}
