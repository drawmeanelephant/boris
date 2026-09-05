//! Table-driven dispatch for the CLI entry.
//!
//! `runPipelineTimed` previously contained a linear `if (command==.plan) ...`
//! chain for 15 commands. This module extracts that chain into a single
//! `dispatchCommand` plus a `commandLabel` helper for the `--timings` report.
//! The `Handlers` table is `Command -> fn` in the issue's wording: the caller
//! (still `main.zig`) supplies its concrete `run*` functions, so this module
//! does not import `main.zig` and there is no import cycle.
//!
//! `mapPathError`, `classifyPublishError`, `reportPublishError`, and
//! `SessionProvider` remain in `main.zig` deliberately.

const std = @import("std");
const Io = std.Io;
const cli = @import("cli.zig");
const diagnostic = @import("diagnostic.zig");
const timings = @import("timings.zig");

pub const ExitCode = diagnostic.ExitCode;
pub const Options = cli.Options;

/// Uniform handler signature. Every leaf in the dispatch table receives the
/// same five arguments; leaves that do not need `recorder` or `environ` simply
/// ignore them. `environ` is `null` when the process `Init` has no environ
/// map (test `runPipeline` without report); the dispatch checks `null` for
/// the standard-site families that require a session root and returns
/// `.session` without calling the handler, mirroring `main.runPipelineTimed`.
pub const Handler = *const fn (
    Io,
    std.mem.Allocator,
    Options,
    ?*timings.Recorder,
    ?*std.process.Environ.Map,
) ExitCode;

/// Concrete table supplied by `main.zig`. Each field is one leaf of the
/// original `runPipelineTimed` chain. The names mirror `main`'s `run*`
/// functions; the table is intentionally explicit rather than an array so the
/// compiler checks exhaustiveness and the call site stays readable.
pub const Handlers = struct {
    plan: Handler,
    standard_site_publish: Handler,
    standard_site_plan: Handler,
    standard_site_records: Handler,
    standard_site_verify: Handler,
    standard_site_login: Handler,
    standard_site_sessions: Handler,
    standard_site_logout: Handler,
    standard_site_smoke: Handler,
    nostr_plan: Handler,
    nostr_sign: Handler,
    nostr_publish: Handler,
    init: Handler,
    recipe_scale: Handler,
    proof_verify: Handler,
    validate: Handler,
    validate_watch: Handler,
    intelligence: Handler,
    rag: Handler,
    context: Handler,
    llms: Handler,
    rss: Handler,
    html: Handler,
    ir: Handler,
};

/// Timings label used by `runPipelineTimed`'s `defer` when `opts.timings` is
/// set. The report is observational and must never affect artifacts or exit
/// codes.
pub fn commandLabel(opts: Options) []const u8 {
    return switch (opts.command) {
        .validate, .check, .impact, .plan, .nostr_plan, .proof_verify => @tagName(opts.command),
        else => @tagName(opts.mode),
    };
}

/// Table-driven dispatch. Mirrors `main.runPipelineTimed`'s command/mode
/// branching but without the linear `if (command==...)` duplication at the
/// call site. Every branch preserves the original `environ orelse .session`
/// guard for the session families.
pub fn dispatchCommand(
    io: Io,
    gpa: std.mem.Allocator,
    opts: Options,
    recorder: ?*timings.Recorder,
    environ: ?*std.process.Environ.Map,
    handlers: Handlers,
) ExitCode {
    if (opts.command == .plan) {
        return handlers.plan(io, gpa, opts, recorder, environ);
    } else if (opts.command == .standard_site) {
        switch (opts.standard_site_command) {
            .publish => {
                if (environ == null) return .session;
                return handlers.standard_site_publish(io, gpa, opts, recorder, environ);
            },
            .plan => return handlers.standard_site_plan(io, gpa, opts, recorder, environ),
            .records => return handlers.standard_site_records(io, gpa, opts, recorder, environ),
            .verify => return handlers.standard_site_verify(io, gpa, opts, recorder, environ),
            .login => {
                if (environ == null) return .session;
                return handlers.standard_site_login(io, gpa, opts, recorder, environ);
            },
            .sessions => {
                if (environ == null) return .session;
                return handlers.standard_site_sessions(io, gpa, opts, recorder, environ);
            },
            .logout => {
                if (environ == null) return .session;
                return handlers.standard_site_logout(io, gpa, opts, recorder, environ);
            },
            .smoke => {
                if (environ == null) return .session;
                return handlers.standard_site_smoke(io, gpa, opts, recorder, environ);
            },
        }
    } else if (opts.command == .nostr_plan) {
        return handlers.nostr_plan(io, gpa, opts, recorder, environ);
    } else if (opts.command == .nostr_sign) {
        return handlers.nostr_sign(io, gpa, opts, recorder, environ);
    } else if (opts.command == .nostr_publish) {
        return handlers.nostr_publish(io, gpa, opts, recorder, environ);
    } else if (opts.command == .init) {
        return handlers.init(io, gpa, opts, recorder, environ);
    } else if (opts.command == .recipe_scale) {
        return handlers.recipe_scale(io, gpa, opts, recorder, environ);
    } else if (opts.command == .proof_verify) {
        return handlers.proof_verify(io, gpa, opts, recorder, environ);
    } else if (opts.command == .validate) {
        if (opts.watch) return handlers.validate_watch(io, gpa, opts, recorder, environ);
        return handlers.validate(io, gpa, opts, recorder, environ);
    } else if (opts.command == .check or opts.command == .impact) {
        return handlers.intelligence(io, gpa, opts, recorder, environ);
    } else switch (opts.mode) {
        .rag => return handlers.rag(io, gpa, opts, recorder, environ),
        .context => return handlers.context(io, gpa, opts, recorder, environ),
        .llms => return handlers.llms(io, gpa, opts, recorder, environ),
        .rss => return handlers.rss(io, gpa, opts, recorder, environ),
        .html => return handlers.html(io, gpa, opts, recorder, environ),
        .ir => return handlers.ir(io, gpa, opts, recorder, environ),
    }
}
