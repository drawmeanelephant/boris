const std = @import("std");
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{}); const optimize = b.standardOptimizeOption(.{});
    const search_mod = b.createModule(.{ .root_source_file = b.path("../../src/search_index.zig"), .target = target, .optimize = optimize });
    const mod = b.createModule(.{ .root_source_file = b.path("main.zig"), .target = target, .optimize = optimize, .imports = &.{.{ .name = "search_index", .module = search_mod }} });
    const exe = b.addExecutable(.{ .name = "boris-search-index", .root_module = mod }); b.installArtifact(exe);
    const run = b.addRunArtifact(exe); run.step.dependOn(b.getInstallStep()); if (b.args) |args| run.addArgs(args);
    const run_step = b.step("run", "Index a rendered Boris HTML directory"); run_step.dependOn(&run.step);
    const tests = b.addTest(.{ .root_module = search_mod }); const run_tests = b.addRunArtifact(tests); const test_step = b.step("test", "Run rendered search tests"); test_step.dependOn(&run_tests.step);
}
