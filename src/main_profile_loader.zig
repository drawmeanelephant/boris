//! Centralized publication profile loading for the CLI.
//!
//! Consolidates the four-step sequence `readFileAlloc + currentPathAlloc +
//! profileWorkspace + parseBytes` that was previously copied across
//! `buildStandardSiteProjection`, `loadHtmlVerification`, `loadHtmlNostr`,
//! `runPublicationPlan`, and `runNostrPlan`. The error mapping
//! `OutOfMemory -> io_error else usage` stays central via
//! `reportPublicationPlanConfigError`.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");
const publication_profile = @import("publication_profile.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const Options = cli.Options;
pub const PublicationRequest = publication_profile.PublicationRequest;
pub const ProfileOverrides = publication_profile.ProfileOverrides;

/// Mirrors `main.reportPublicationPlanConfigError`: invalid profile is usage
/// (exit 2) unless it is an allocator failure, which is an I/O/system failure
/// (exit 3). Central so every profile-reading path uses one mapping.
pub fn reportPublicationPlanConfigError(err: anyerror) ExitCode {
    std.debug.print("error: invalid publication profile: {s}\n", .{@errorName(err)});
    return switch (err) {
        error.OutOfMemory => .io_error,
        else => .usage,
    };
}

/// Derive the `ProfileOverrides` that `publication_profile.parseBytes` expects
/// from the CLI `Options`. All fields are taken verbatim; `null` means
/// "no override". The `input_format` enum is translated from `cli`'s view to
/// `publication_profile`'s identical but distinct type.
pub fn profileOverridesFromOptions(opts: Options) ProfileOverrides {
    const fmt: ?publication_profile.InputFormat = if (opts.profile_input_format_override) |format| switch (format) {
        .markdown => .markdown,
        .textile => .textile,
        .cook => .cook,
    } else null;
    return .{
        .input = opts.profile_input_override,
        .input_format = fmt,
        .html_output = opts.profile_html_output_override,
        .jobs = opts.jobs,
        .incremental = opts.incremental,
        .quiet = opts.quiet,
    };
}

/// Pure helper: read, resolve workspace, and parse a profile into an owned
/// `PublicationRequest`. No diagnostics are printed; the caller decides how to
/// map the error to an exit code. `StreamTooLong` from the bounded read is
/// translated to `ProfileTooLarge` so the config-error path is uniform.
pub fn readProfileRequest(
    gpa: std.mem.Allocator,
    io: Io,
    profile_path: []const u8,
    overrides: ProfileOverrides,
) !PublicationRequest {
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return error.ProfileTooLarge,
        else => return err,
    };
    defer gpa.free(profile_bytes);

    const cwd_path = try std.process.currentPathAlloc(io, gpa);
    defer gpa.free(cwd_path);

    const workspace = try publication_profile.profileWorkspace(gpa, cwd_path, profile_path);

    return try publication_profile.parseBytes(gpa, workspace, profile_bytes, overrides);
}

/// Convenience that derives `profile_path` and `overrides` from `opts` and
/// delegates to `readProfileRequest`. The caller must have ensured
/// `opts.profile_path != null` before calling; otherwise returns
/// `error.MissingField`.
pub fn readProfileRequestFromOptions(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
) !PublicationRequest {
    const profile_path = opts.profile_path orelse return error.MissingField;
    const overrides = profileOverridesFromOptions(opts);
    return readProfileRequest(gpa, io, profile_path, overrides);
}

/// Checked helper that performs the same four-step sequence but prints the
/// two I/O diagnostics directly and maps every failure to an `ExitCode`,
/// filling `out` on success. This is the one-call replacement for the five
/// previously duplicated blocks.
pub fn loadProfileRequest(
    gpa: std.mem.Allocator,
    io: Io,
    profile_path: []const u8,
    overrides: ProfileOverrides,
    out: *PublicationRequest,
) ExitCode {
    const profile_bytes = Io.Dir.cwd().readFileAlloc(
        io,
        profile_path,
        gpa,
        .limited(publication_profile.max_profile_bytes + 1),
    ) catch |err| switch (err) {
        error.StreamTooLong => return reportPublicationPlanConfigError(error.ProfileTooLarge),
        else => {
            std.debug.print("error: unable to read publication profile: {s}\n", .{@errorName(err)});
            return .io_error;
        },
    };
    defer gpa.free(profile_bytes);

    const cwd_path = std.process.currentPathAlloc(io, gpa) catch |err| {
        std.debug.print("error: unable to resolve publication profile workspace: {s}\n", .{@errorName(err)});
        return .io_error;
    };
    defer gpa.free(cwd_path);

    const workspace = publication_profile.profileWorkspace(gpa, cwd_path, profile_path) catch |err| {
        return reportPublicationPlanConfigError(err);
    };

    const request = publication_profile.parseBytes(gpa, workspace, profile_bytes, overrides) catch |err| {
        return reportPublicationPlanConfigError(err);
    };
    out.* = request;
    return .success;
}

/// Variant that derives `profile_path` and `overrides` from `opts`.
/// Returns `.usage` when `opts.profile_path` is absent (required-profile
/// commands). Callers where the profile is optional (HTML verification/
/// Nostr head) must check `opts.profile_path` before calling.
pub fn loadProfileRequestFromOptions(
    gpa: std.mem.Allocator,
    io: Io,
    opts: Options,
    out: *PublicationRequest,
) ExitCode {
    const profile_path = opts.profile_path orelse return .usage;
    const overrides = profileOverridesFromOptions(opts);
    return loadProfileRequest(gpa, io, profile_path, overrides, out);
}
