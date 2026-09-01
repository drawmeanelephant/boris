// Pinned-API test for the published `parser` package module.
//
// This test consumes the module exactly the way a dependent build does:
// by the registered module name "parser" through the build-graph import,
// never by relative file path. It pins the stable package surface that
// external consumers (e.g. the migration laboratory, once it is split into
// its own repository) rely on: a `parse([]const u8) ParseResult` entry
// point whose `diagnostic` is null for well-formed source. If the package
// module is renamed, unwired, or its parse entry changes shape, this test
// fails even though the in-tree parser tests still pass.
const std = @import("std");
const parser = @import("parser");

test "parser package module exposes a stable parse entry point" {
    const ok = parser.parse("---\ntitle: T\n---\n\nbody\n");
    try std.testing.expect(ok.diagnostic == null);

    const bad = parser.parse("---\nbroken: [\n---\n\nbody\n");
    try std.testing.expect(bad.diagnostic != null);
}
