//! Deterministic pixel-dimension extraction for common image formats, used to
//! extend published asset records (#396). "Where determinable": unknown or
//! unsupported formats, malformed headers, and degenerate zero dimensions all
//! yield null rather than a guess. No decoding is performed — only header
//! bytes are inspected, so the source bytes are never altered and hashes stay
//! consistent with what is published.
const std = @import("std");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

/// Dispatch on the path extension. Supported: PNG, GIF, JPEG, WebP, BMP, SVG.
/// Returns null for any other extension or when the bytes cannot be read.
pub fn dimensions(path: []const u8, bytes: []const u8) ?Dimensions {
    const ext = extensionOf(path) orelse return null;
    if (std.ascii.eqlIgnoreCase(ext, ".png")) return png(bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".gif")) return gif(bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".jpg") or std.ascii.eqlIgnoreCase(ext, ".jpeg")) return jpeg(bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".webp")) return webp(bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".bmp")) return bmp(bytes);
    if (std.ascii.eqlIgnoreCase(ext, ".svg")) return svg(bytes);
    return null;
}

fn extensionOf(path: []const u8) ?[]const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return null;
    return base[dot..];
}

fn be16(bytes: []const u8, at: usize) ?u32 {
    if (at + 2 > bytes.len) return null;
    return (@as(u32, bytes[at]) << 8) | bytes[at + 1];
}

fn be32(bytes: []const u8, at: usize) ?u32 {
    if (at + 4 > bytes.len) return null;
    return (@as(u32, bytes[at]) << 24) |
        (@as(u32, bytes[at + 1]) << 16) |
        (@as(u32, bytes[at + 2]) << 8) |
        bytes[at + 3];
}

fn le16(bytes: []const u8, at: usize) ?u32 {
    if (at + 2 > bytes.len) return null;
    return bytes[at] | (@as(u32, bytes[at + 1]) << 8);
}

fn le32(bytes: []const u8, at: usize) ?u32 {
    if (at + 4 > bytes.len) return null;
    return bytes[at] |
        (@as(u32, bytes[at + 1]) << 8) |
        (@as(u32, bytes[at + 2]) << 16) |
        (@as(u32, bytes[at + 3]) << 24);
}

fn sanitize(width: u32, height: u32) ?Dimensions {
    // A zero dimension is degenerate (PNG/GIF/BMP explicitly forbid it).
    if (width == 0 or height == 0) return null;
    return .{ .width = width, .height = height };
}

/// PNG: 8-byte signature, then the IHDR chunk carries 13-byte data with
/// big-endian width and height at fixed offsets.
fn png(bytes: []const u8) ?Dimensions {
    const sig = "\x89PNG\r\n\x1a\n";
    if (bytes.len < 24 or !std.mem.startsWith(u8, bytes, sig)) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    const width = be32(bytes, 16) orelse return null;
    const height = be32(bytes, 20) orelse return null;
    return sanitize(width, height);
}

/// GIF: 6-byte signature, then little-endian width/height at offsets 6 and 8.
fn gif(bytes: []const u8) ?Dimensions {
    if (bytes.len < 10) return null;
    if (!std.mem.startsWith(u8, bytes, "GIF87a") and
        !std.mem.startsWith(u8, bytes, "GIF89a")) return null;
    const width = le16(bytes, 6) orelse return null;
    const height = le16(bytes, 8) orelse return null;
    return sanitize(width, height);
}

/// JPEG: walk the marker stream looking for a start-of-frame (SOF) segment
/// whose height/width fields are big-endian. `i` points at the marker byte
/// (leading 0xFF fill bytes are consumed by the loop).
fn jpeg(bytes: []const u8) ?Dimensions {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return null;
    var i: usize = 2;
    while (i + 4 <= bytes.len) {
        if (bytes[i] != 0xFF) {
            // Data segment without a marker (should not occur before SOF);
            // bail rather than guess.
            return null;
        }
        // Skip fill bytes.
        while (i < bytes.len and bytes[i] == 0xFF) i += 1;
        if (i >= bytes.len) return null;
        const marker = bytes[i];
        if (marker == 0xD9 or marker == 0xDA) return null; // EOI / SOS
        if (marker >= 0xC0 and marker <= 0xCF and marker != 0xC4 and marker != 0xC8 and marker != 0xCC) {
            // SOF segment: marker(i) length(i+1..i+2) precision(i+3)
            // height(i+4..i+5) width(i+6..i+7)
            const height = be16(bytes, i + 4) orelse return null;
            const width = be16(bytes, i + 6) orelse return null;
            return sanitize(width, height);
        }
        const seg_len = be16(bytes, i + 1) orelse return null;
        if (seg_len < 2) return null;
        i += 1 + seg_len;
    }
    return null;
}

/// WebP: RIFF container; dimensions depend on the VP8 / VP8L / VP8X chunk.
fn webp(bytes: []const u8) ?Dimensions {
    // Minimum container: RIFF(4) size(4) WEBP(4) fourcc(4) chunk-size(4).
    // Each variant imposes its own chunk-data minimum below.
    if (bytes.len < 20) return null;
    if (!std.mem.startsWith(u8, bytes, "RIFF") or
        !std.mem.eql(u8, bytes[8..12], "WEBP")) return null;
    const fourcc = bytes[12..16];
    const chunk_size = le32(bytes, 16) orelse return null;
    if (16 + 4 + chunk_size > bytes.len) return null;
    const data = bytes[20 .. 20 + chunk_size];

    if (std.mem.eql(u8, fourcc, "VP8 ")) {
        // Lossy: frame tag(3) start code(3) then 14-bit little-endian w/h.
        if (data.len < 10) return null;
        if (!std.mem.eql(u8, data[3..6], "\x9d\x01\x2a")) return null;
        const width = (data[6] | (@as(u32, data[7]) << 8)) & 0x3FFF;
        const height = (data[8] | (@as(u32, data[9]) << 8)) & 0x3FFF;
        return sanitize(width, height);
    }
    if (std.mem.eql(u8, fourcc, "VP8L")) {
        // Lossless: 0x2F signature then packed 14-bit width/height, minus one.
        if (data.len < 5 or data[0] != 0x2F) return null;
        const width = (@as(u32, data[1]) | (@as(u32, data[2] & 0x3F) << 8)) + 1;
        const height = ((@as(u32, data[2] & 0xC0) >> 6) |
            (@as(u32, data[3]) << 2) |
            (@as(u32, data[4] & 0x0F) << 10)) + 1;
        return sanitize(width, height);
    }
    if (std.mem.eql(u8, fourcc, "VP8X")) {
        // Extended: flags(1) reserved(3) then 24-bit little-endian w/h, minus one.
        if (data.len < 10) return null;
        const width = (data[4] | (@as(u32, data[5]) << 8) | (@as(u32, data[6]) << 16)) + 1;
        const height = (data[7] | (@as(u32, data[8]) << 8) | (@as(u32, data[9]) << 16)) + 1;
        return sanitize(width, height);
    }
    return null;
}

/// BMP: "BM" signature; width/height are little-endian at offsets 18 and 22.
/// A negative height (top-down bitmap) is stored as its absolute value.
fn bmp(bytes: []const u8) ?Dimensions {
    if (bytes.len < 26 or !std.mem.startsWith(u8, bytes, "BM")) return null;
    const width = le32(bytes, 18) orelse return null;
    const height_raw = le32(bytes, 22) orelse return null;
    const height: u32 = if (height_raw > std.math.maxInt(i32))
        @intCast(@abs(@as(i64, @as(i32, @bitCast(height_raw)))))
    else
        height_raw;
    return sanitize(width, height);
}

/// SVG: read `width` / `height` attributes (numeric, unitless or px) or the
/// `viewBox` width/height from the root `<svg>` open tag. No XML parsing —
/// the scan is bounded to the open tag and is case-insensitive.
fn svg(bytes: []const u8) ?Dimensions {
    const tag_start = indexOfIgnoreCase(bytes, "<svg") orelse return null;
    const tag_end = std.mem.indexOfScalarPos(u8, bytes, tag_start, '>') orelse return null;
    const tag = bytes[tag_start..tag_end];

    const w = numericAttr(tag, "width");
    const h = numericAttr(tag, "height");
    if (w != null and h != null) return sanitize(w.?, h.?);

    if (viewBox(tag)) |vb| return sanitize(vb.width, vb.height);
    return null;
}

const ViewBox = struct { width: u32, height: u32 };

fn viewBox(tag: []const u8) ?ViewBox {
    const name = attributeValue(tag, "viewbox") orelse return null;
    // Four numbers: min-x min-y width height.
    var values: [4]u32 = undefined;
    var count: usize = 0;
    var rest = name;
    while (count < 4) : (count += 1) {
        rest = skipWhitespace(rest);
        const num = parseNumber(rest) orelse return null;
        values[count] = num.value;
        rest = num.rest;
    }
    if (values[0] > std.math.maxInt(u32) - values[2] or values[1] > std.math.maxInt(u32) - values[3]) return null;
    return .{ .width = values[2], .height = values[3] };
}

const Number = struct { value: u32, rest: []const u8 };

/// Parse a leading non-negative integer (or integer-decimal) and return the
/// remainder. Only unitless values are accepted for viewBox numbers.
fn parseNumber(s: []const u8) ?Number {
    var i: usize = 0;
    while (i < s.len and s[i] >= '0' and s[i] <= '9') i += 1;
    if (i == 0) return null;
    const number = std.fmt.parseInt(u32, s[0..i], 10) catch return null;
    var rest = s[i..];
    if (rest.len > 0 and rest[0] == '.') {
        // Decimal part is ignored for pixel dimensions (fractional px rounds
        // down per SVG 1.1); just consume the digits.
        var j: usize = 1;
        while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') j += 1;
        rest = rest[j..];
    }
    return .{ .value = number, .rest = rest };
}

/// Numeric attribute value (`width="640"`, `width="640px"`, `width='50%'`).
/// Returns null for non-numeric or percentage values.
fn numericAttr(tag: []const u8, attr: []const u8) ?u32 {
    const value = attributeValue(tag, attr) orelse return null;
    var i: usize = 0;
    while (i < value.len and value[i] >= '0' and value[i] <= '9') i += 1;
    if (i == 0) return null;
    const number = std.fmt.parseInt(u32, value[0..i], 10) catch return null;
    var rest = value[i..];
    if (rest.len > 0 and rest[0] == '.') {
        var j: usize = 1;
        while (j < rest.len and rest[j] >= '0' and rest[j] <= '9') j += 1;
        rest = rest[j..];
    }
    if (rest.len == 0 or std.mem.eql(u8, rest, "px")) return number;
    return null;
}

fn attributeValue(tag: []const u8, attr: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < tag.len) {
        // Find the attribute name (case-insensitive, word-bounded).
        var j = i;
        while (j + attr.len <= tag.len) : (j += 1) {
            if (asciiEqualFold(tag[j .. j + attr.len], attr)) {
                const before_ok = j == 0 or !isWordChar(tag[j - 1]);
                const after_ok = j + attr.len >= tag.len or !isWordChar(tag[j + attr.len]);
                if (before_ok and after_ok) {
                    var k = j + attr.len;
                    while (k < tag.len and (tag[k] == ' ' or tag[k] == '\t' or tag[k] == '\n' or tag[k] == '\r')) k += 1;
                    if (k < tag.len and tag[k] == '=') {
                        k += 1;
                        while (k < tag.len and (tag[k] == ' ' or tag[k] == '\t' or tag[k] == '\n' or tag[k] == '\r')) k += 1;
                        if (k < tag.len and (tag[k] == '"' or tag[k] == '\'')) {
                            const quote = tag[k];
                            k += 1;
                            const start = k;
                            while (k < tag.len and tag[k] != quote) k += 1;
                            if (k >= tag.len) return null;
                            return tag[start..k];
                        }
                    }
                }
            }
        }
        // Skip to the next whitespace/`/`/`>` boundary to avoid quadratic
        // re-scans within one attribute token.
        while (i < tag.len and !isWordChar(tag[i])) i += 1;
        while (i < tag.len and isWordChar(tag[i])) i += 1;
    }
    return null;
}

fn indexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (asciiEqualFold(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn asciiEqualFold(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    }
    return true;
}

fn isWordChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-';
}

fn skipWhitespace(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len and (s[i] == ' ' or s[i] == '\t' or s[i] == '\n' or s[i] == '\r' or s[i] == ',')) i += 1;
    return s[i..];
}

// ---------------------------------------------------------------------------

const t = std.testing;

fn pngBytes(width: u32, height: u32) [24]u8 {
    var bytes: [24]u8 = undefined;
    @memcpy(bytes[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(bytes[8..12], &[_]u8{ 0, 0, 0, 13 });
    @memcpy(bytes[12..16], "IHDR");
    bytes[16] = @truncate(width >> 24);
    bytes[17] = @truncate(width >> 16);
    bytes[18] = @truncate(width >> 8);
    bytes[19] = @truncate(width);
    bytes[20] = @truncate(height >> 24);
    bytes[21] = @truncate(height >> 16);
    bytes[22] = @truncate(height >> 8);
    bytes[23] = @truncate(height);
    return bytes;
}

test "png dimensions from IHDR" {
    const bytes = pngBytes(320, 200);
    const d = png(&bytes).?;
    try t.expectEqual(@as(u32, 320), d.width);
    try t.expectEqual(@as(u32, 200), d.height);
}

test "png truncated and non-png return null" {
    try t.expect(png("not png") == null);
    var short: [16]u8 = undefined;
    @memcpy(short[0..8], "\x89PNG\r\n\x1a\n");
    @memcpy(short[8..12], &[_]u8{ 0, 0, 0, 13 });
    @memcpy(short[12..16], "IHDR");
    try t.expect(png(&short) == null);
    // Zero dimensions are degenerate.
    const zero = pngBytes(0, 0);
    try t.expect(png(&zero) == null);
}

test "gif dimensions" {
    const gif_bytes = "GIF89a" ++ [_]u8{ 0x40, 0x01, 0xC8, 0x00 } ++ "rest";
    const d = gif(gif_bytes).?;
    try t.expectEqual(@as(u32, 320), d.width);
    try t.expectEqual(@as(u32, 200), d.height);
}

test "jpeg dimensions walk the marker stream" {
    // SOI + APP0 + SOF0 (width 640, height 480).
    const jpg = [_]u8{
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x10, 'J', 'F', 'I', 'F', 0, 1, 1, 0, 0, 1, 0, 1, 0, 0,
        0xFF, 0xC0, 0x00, 0x11, 8,
        0x01, 0xE0, // height 480
        0x02, 0x80, // width 640
    };
    const d = jpeg(&jpg).?;
    try t.expectEqual(@as(u32, 640), d.width);
    try t.expectEqual(@as(u32, 480), d.height);
    try t.expect(jpeg("nope") == null);
}

test "webp vp8 lossy, vp8l lossless, and vp8x dimensions" {
    // VP8 lossy: RIFF..WEBP, VP8  chunk, frame tag + start code + 14-bit w/h.
    var lossy: std.ArrayList(u8) = .empty;
    defer lossy.deinit(t.allocator);
    try lossy.appendSlice(t.allocator, "RIFF");
    try lossy.appendSlice(t.allocator, &[_]u8{ 30, 0, 0, 0 });
    try lossy.appendSlice(t.allocator, "WEBPVP8 ");
    try lossy.appendSlice(t.allocator, &[_]u8{ 10, 0, 0, 0 });
    try lossy.appendSlice(t.allocator, &[_]u8{ 0x10, 0x02, 0, 0x9D, 0x01, 0x2A, 0x40, 0x01, 0x58, 0x02 });
    const dl = webp(lossy.items).?;
    try t.expectEqual(@as(u32, 320), dl.width);
    try t.expectEqual(@as(u32, 600), dl.height);

    // VP8L lossless: 0x2F signature then packed width-1 (319) / height-1 (199).
    // width-1 bits 0-13, height-1 bits 14-27, LSB-first: 0x3F, 0xC1, 0x31, 0x00.
    var lossless: std.ArrayList(u8) = .empty;
    defer lossless.deinit(t.allocator);
    try lossless.appendSlice(t.allocator, "RIFF");
    try lossless.appendSlice(t.allocator, &[_]u8{ 25, 0, 0, 0 });
    try lossless.appendSlice(t.allocator, "WEBPVP8L");
    try lossless.appendSlice(t.allocator, &[_]u8{ 5, 0, 0, 0 });
    try lossless.appendSlice(t.allocator, &[_]u8{ 0x2F, 0x3F, 0xC1, 0x31, 0x00 });
    const dl2 = webp(lossless.items).?;
    try t.expectEqual(@as(u32, 320), dl2.width);
    try t.expectEqual(@as(u32, 200), dl2.height);

    // VP8X extended: 24-bit w-1/h-1.
    var ext: std.ArrayList(u8) = .empty;
    defer ext.deinit(t.allocator);
    try ext.appendSlice(t.allocator, "RIFF");
    try ext.appendSlice(t.allocator, &[_]u8{ 30, 0, 0, 0 });
    try ext.appendSlice(t.allocator, "WEBPVP8X");
    try ext.appendSlice(t.allocator, &[_]u8{ 10, 0, 0, 0 });
    try ext.appendSlice(t.allocator, &[_]u8{ 0, 0, 0, 0, 0x3F, 0x01, 0x00, 0xC7, 0x00, 0x00 });
    const dx = webp(ext.items).?;
    try t.expectEqual(@as(u32, 320), dx.width);
    try t.expectEqual(@as(u32, 200), dx.height);
}

test "bmp dimensions with top-down height" {
    var bytes: [26]u8 = undefined;
    @memset(&bytes, 0);
    @memcpy(bytes[0..2], "BM");
    bytes[18] = 0x80; bytes[19] = 0x02; // width 640
    bytes[22] = 0xD4; bytes[23] = 0xFE; bytes[24] = 0xFF; bytes[25] = 0xFF; // -300 as i32 (top-down)
    const d = bmp(&bytes).?;
    try t.expectEqual(@as(u32, 640), d.width);
    try t.expectEqual(@as(u32, 300), d.height);
}

test "svg width/height attributes and viewBox fallback" {
    const with_attrs = "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"120\" height=\"80\"><rect/></svg>";
    const d = svg(with_attrs).?;
    try t.expectEqual(@as(u32, 120), d.width);
    try t.expectEqual(@as(u32, 80), d.height);

    const px = "<svg width='64px' height='48px'></svg>";
    const dp = svg(px).?;
    try t.expectEqual(@as(u32, 64), dp.width);
    try t.expectEqual(@as(u32, 48), dp.height);

    const viewbox_only = "<svg viewBox=\"0 0 200 100\"></svg>";
    const dv = svg(viewbox_only).?;
    try t.expectEqual(@as(u32, 200), dv.width);
    try t.expectEqual(@as(u32, 100), dv.height);

    const percentage = "<svg width=\"50%\" height=\"50%\"></svg>";
    try t.expect(svg(percentage) == null);

    const no_svg = "<html></html>";
    try t.expect(svg(no_svg) == null);
}

test "dispatch honors the path extension" {
    const png_bytes = pngBytes(320, 200);
    const d = dimensions("assets/logo.png", &png_bytes);
    try t.expect(d != null);
    try t.expectEqual(@as(u32, 320), d.?.width);
    try t.expect(dimensions("assets/logo.unknown", &png_bytes) == null);
    try t.expect(dimensions("assets/logo.png", "not png") == null);
}
