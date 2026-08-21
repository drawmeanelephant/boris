const std = @import("std");

pub const embedded_css =
    \\  /* Embedded bounded CSS. No external fonts, scripts, images, or stylesheets. */
    \\  :root {
    \\    color-scheme: light;
    \\    --ink: #1a1a1a;
    \\    --muted: #555;
    \\    --line: #ccc;
    \\    --bg: #ffffff;
    \\    --panel: #fafafa;
    \\    --accent: #0b5cad;
    \\    --pass-bg: #eaf6ec;
    \\    --pass-ink: #1f6b2f;
    \\    --warn-bg: #fdf3e3;
    \\    --warn-ink: #8a5a00;
    \\    --bad-bg: #fdecea;
    \\    --bad-ink: #a3261e;
    \\    --na-bg: #eef0f2;
    \\    --na-ink: #444;
    \\    --mono: ui-monospace, SFMono-Regular, Menlo, Consolas, monospace;
    \\  }
    \\  * { box-sizing: border-box; }
    \\  body {
    \\    margin: 0 auto;
    \\    max-width: 1000px;
    \\    padding: 1.5rem 1.25rem 3rem;
    \\    font-family: system-ui, -apple-system, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    \\    font-size: 0.95rem;
    \\    line-height: 1.55;
    \\    color: var(--ink);
    \\    background: var(--bg);
    \\  }
    \\  header h1 { font-size: 1.5rem; margin: 0 0 0.25rem; }
    \\  .meta { color: var(--muted); font-size: 0.85rem; }
    \\  .banner {
    \\    margin: 1rem 0 1.5rem;
    \\    padding: 0.75rem 1rem;
    \\    border: 1px solid var(--line);
    \\    border-radius: 6px;
    \\    font-weight: 600;
    \\  }
    \\  .banner.verified { background: var(--pass-bg); color: var(--pass-ink); }
    \\  .banner.attention { background: var(--bad-bg); color: var(--bad-ink); }
    \\  .banner.incomplete { background: var(--warn-bg); color: var(--warn-ink); }
    \\  .banner.na { background: var(--na-bg); color: var(--na-ink); }
    \\  nav { margin: 0 0 1.5rem; }
    \\  nav ul { list-style: none; padding: 0; margin: 0; display: flex; flex-wrap: wrap; gap: 0.5rem 1rem; }
    \\  nav a { color: var(--accent); text-decoration: none; }
    \\  nav a:hover { text-decoration: underline; }
    \\  h2 {
    \\    font-size: 1.25rem;
    \\    margin: 2.25rem 0 0.6rem;
    \\    padding-bottom: 0.3rem;
    \\    border-bottom: 1px solid var(--line);
    \\  }
    \\  h3 { font-size: 1.05rem; margin: 1.25rem 0 0.4rem; }
    \\  .table-wrap { overflow-x: auto; margin: 0.5rem 0 1rem; }
    \\  table { width: 100%; border-collapse: collapse; }
    \\  th, td {
    \\    text-align: left;
    \\    padding: 0.45rem 0.5rem;
    \\    border: 1px solid var(--line);
    \\    vertical-align: top;
    \\    overflow-wrap: anywhere;
    \\    word-break: break-word;
    \\  }
    \\  th { background: #f4f4f4; font-weight: 600; }
    \\  code, .mono {
    \\    font-family: var(--mono);
    \\    font-size: 0.85em;
    \\    overflow-wrap: anywhere;
    \\    word-break: break-word;
    \\  }
    \\  .status-passed, .status-verified { color: var(--pass-ink); font-weight: 600; }
    \\  .status-failed, .status-attention { color: var(--bad-ink); font-weight: 600; }
    \\  .status-incomplete { color: var(--warn-ink); font-weight: 600; }
    \\  .status-na { color: var(--na-ink); font-weight: 600; }
    \\  .empty { color: var(--muted); font-style: italic; margin: 0.25rem 0 1rem; }
    \\  ul.plain { margin: 0.25rem 0 1rem; padding-left: 1.25rem; }
    \\  .src { color: var(--muted); font-size: 0.8rem; }
    \\  details { margin: 0.75rem 0 1rem; border: 1px solid var(--line); border-radius: 6px; background: var(--panel); }
    \\  details > summary {
    \\    cursor: pointer;
    \\    padding: 0.55rem 0.75rem;
    \\    font-weight: 600;
    \\  }
    \\  details[open] > summary { border-bottom: 1px solid var(--line); }
    \\  details > summary:hover { background: #f0f0f0; }
    \\  .edge-explain { color: var(--muted); font-size: 0.9rem; margin: 0 0.75rem 0.5rem; }
    \\  footer { margin-top: 2.5rem; padding-top: 0.75rem; border-top: 1px solid var(--line); color: var(--muted); font-size: 0.8rem; }
    \\  @media print {
    \\    nav { display: none; }
    \\    body { max-width: none; padding: 0.5rem; }
    \\    a { color: inherit; text-decoration: none; }
    \\    details,
    \\    details > summary { display: block; }
    \\    details::details-content { content-visibility: visible !important; display: block !important; }
    \\    details > :not(summary) { display: block !important; }
    \\    .table-wrap { overflow: visible; }
    \\    h2, h3 { break-after: avoid; }
    \\    tr, li { break-inside: avoid; }
    \\  }
;

pub fn writeHtmlNumber(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: usize) !void {
    var tmp: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&tmp, "{d}", .{value});
    try out.appendSlice(gpa, text);
}

pub fn escapeHtml(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    for (value) |byte| switch (byte) {
        '&' => try out.appendSlice(gpa, "&amp;"),
        '<' => try out.appendSlice(gpa, "&lt;"),
        '>' => try out.appendSlice(gpa, "&gt;"),
        '"' => try out.appendSlice(gpa, "&quot;"),
        '\'' => try out.appendSlice(gpa, "&#39;"),
        else => try out.append(gpa, byte),
    };
}

pub fn writeHtmlEscaped(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try escapeHtml(out, gpa, value);
}

pub fn writeHtmlCode(out: *std.ArrayList(u8), gpa: std.mem.Allocator, value: []const u8) !void {
    try out.appendSlice(gpa, "<code>");
    try writeHtmlEscaped(out, gpa, value);
    try out.appendSlice(gpa, "</code>");
}

pub fn joinHtmlList(out: *std.ArrayList(u8), gpa: std.mem.Allocator, values: []const []const u8, fallback: []const u8) !void {
    if (values.len == 0) {
        try writeHtmlEscaped(out, gpa, fallback);
        return;
    }
    for (values, 0..) |value, index| {
        if (index > 0) try out.appendSlice(gpa, ", ");
        try writeHtmlEscaped(out, gpa, value);
    }
}
