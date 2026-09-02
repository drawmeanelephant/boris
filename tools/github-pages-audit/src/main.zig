//! CLI wrapper for the standalone post-deploy GitHub Pages observer.

const std = @import("std");
const Io = std.Io;
const audit = @import("audit");

const Options = struct {
    plan_path: []const u8,
    inventory_path: []const u8,
    page_url: []const u8,
    out_path: []const u8,
    audited_at: []const u8,
    target: []const u8 = "public",
    repository: ?[]const u8 = null,
    source_commit: ?[]const u8 = null,
    workflow_ref: ?[]const u8 = null,
    workflow_sha: ?[]const u8 = null,
    run_id: ?[]const u8 = null,
    run_attempt: ?[]const u8 = null,
    deployment_id: ?[]const u8 = null,
    public_artifact_name: ?[]const u8 = null,
    bounds: audit.Bounds = .{},
};

const CliError = error{
    Help,
    Version,
    MissingValue,
    UnknownFlag,
    MissingRequiredOption,
    InvalidNumber,
};

/// Tool id printed by `--version`/`-V`. Kept in lockstep with the product
/// release line (`pipeline.boris_version`); this tool does not import `src/`.
pub const tool_id = "boris-github-pages-audit/0.8.2";

fn usage() void {
    std.debug.print(
        "Usage: boris-github-pages-audit --plan FILE --inventory FILE --page-url URL --audited-at ISO-8601 --out FILE [OPTIONS]\n" ++
            "\n" ++
            "Inputs and output:\n" ++
            "  --plan FILE                 Normalized publication-plan.json\n" ++
            "  --inventory FILE            Target-local proof/artifacts.json\n" ++
            "  --page-url URL              deploy-pages page_url output\n" ++
            "  --audited-at TIMESTAMP      Explicit audit timestamp (no implicit clock)\n" ++
            "  --out FILE                  Deployment-evidence JSON path\n" ++
            "  --target NAME               Inventory target (default: public)\n" ++
            "\n" ++
            "Workflow identity:\n" ++
            "  --repository VALUE          Repository identity\n" ++
            "  --source-commit VALUE       Published source commit\n" ++
            "  --workflow-ref VALUE        Workflow ref\n" ++
            "  --workflow-sha VALUE        Workflow definition SHA\n" ++
            "  --run-id VALUE              Workflow run id\n" ++
            "  --run-attempt VALUE         Workflow run attempt\n" ++
            "  --deployment-id VALUE       Deployment id when reliably available\n" ++
            "  --public-artifact-name VAL  Public artifact identity when reliable\n" ++
            "\n" ++
            "Bounds:\n" ++
            "  --max-requests N            Total HTTP requests including redirects (default: 256)\n" ++
            "  --max-body-bytes N          Decoded response body bound (default: 8388608)\n" ++
            "  --max-redirects N           Redirect hops per URL (default: 3)\n" ++
            "  --timeout-ms N              Per-request timeout (default: 10000)\n" ++
            "  --max-projection-urls N     URLs parsed per projection/HTML page (default: 256)\n" ++
            "  --help                      Show this help\n" ++
            "  --version                   Print the tool id and exit\n",
        .{},
    );
}

fn optionValue(args: []const []const u8, index: *usize, arg: []const u8, name: []const u8) CliError![]const u8 {
    if (arg.len > name.len and std.mem.startsWith(u8, arg, name) and arg[name.len] == '=') {
        const value = arg[name.len + 1 ..];
        if (value.len == 0) return error.MissingValue;
        return value;
    }
    if (!std.mem.eql(u8, arg, name)) return error.UnknownFlag;
    index.* += 1;
    if (index.* >= args.len or args[index.*].len == 0) return error.MissingValue;
    return args[index.*];
}

fn parseNumber(value: []const u8) CliError!usize {
    return std.fmt.parseUnsigned(usize, value, 10) catch error.InvalidNumber;
}

fn parse(args: []const []const u8) CliError!Options {
    var options = Options{
        .plan_path = "",
        .inventory_path = "",
        .page_url = "",
        .out_path = "",
        .audited_at = "",
    };
    var i: usize = if (args.len > 0) 1 else 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            usage();
            return error.Help;
        }
        if (std.mem.eql(u8, arg, "--version") or std.mem.eql(u8, arg, "-V")) {
            return error.Version;
        }
        if (std.mem.startsWith(u8, arg, "--plan=") or std.mem.eql(u8, arg, "--plan")) {
            options.plan_path = try optionValue(args, &i, arg, "--plan");
        } else if (std.mem.startsWith(u8, arg, "--inventory=") or std.mem.eql(u8, arg, "--inventory")) {
            options.inventory_path = try optionValue(args, &i, arg, "--inventory");
        } else if (std.mem.startsWith(u8, arg, "--page-url=") or std.mem.eql(u8, arg, "--page-url")) {
            options.page_url = try optionValue(args, &i, arg, "--page-url");
        } else if (std.mem.startsWith(u8, arg, "--out=") or std.mem.eql(u8, arg, "--out")) {
            options.out_path = try optionValue(args, &i, arg, "--out");
        } else if (std.mem.startsWith(u8, arg, "--audited-at=") or std.mem.eql(u8, arg, "--audited-at")) {
            options.audited_at = try optionValue(args, &i, arg, "--audited-at");
        } else if (std.mem.startsWith(u8, arg, "--target=") or std.mem.eql(u8, arg, "--target")) {
            options.target = try optionValue(args, &i, arg, "--target");
        } else if (std.mem.startsWith(u8, arg, "--repository=") or std.mem.eql(u8, arg, "--repository")) {
            options.repository = try optionValue(args, &i, arg, "--repository");
        } else if (std.mem.startsWith(u8, arg, "--source-commit=") or std.mem.eql(u8, arg, "--source-commit")) {
            options.source_commit = try optionValue(args, &i, arg, "--source-commit");
        } else if (std.mem.startsWith(u8, arg, "--workflow-ref=") or std.mem.eql(u8, arg, "--workflow-ref")) {
            options.workflow_ref = try optionValue(args, &i, arg, "--workflow-ref");
        } else if (std.mem.startsWith(u8, arg, "--workflow-sha=") or std.mem.eql(u8, arg, "--workflow-sha")) {
            options.workflow_sha = try optionValue(args, &i, arg, "--workflow-sha");
        } else if (std.mem.startsWith(u8, arg, "--run-id=") or std.mem.eql(u8, arg, "--run-id")) {
            options.run_id = try optionValue(args, &i, arg, "--run-id");
        } else if (std.mem.startsWith(u8, arg, "--run-attempt=") or std.mem.eql(u8, arg, "--run-attempt")) {
            options.run_attempt = try optionValue(args, &i, arg, "--run-attempt");
        } else if (std.mem.startsWith(u8, arg, "--deployment-id=") or std.mem.eql(u8, arg, "--deployment-id")) {
            options.deployment_id = try optionValue(args, &i, arg, "--deployment-id");
        } else if (std.mem.startsWith(u8, arg, "--public-artifact-name=") or std.mem.eql(u8, arg, "--public-artifact-name")) {
            options.public_artifact_name = try optionValue(args, &i, arg, "--public-artifact-name");
        } else if (std.mem.startsWith(u8, arg, "--max-requests=") or std.mem.eql(u8, arg, "--max-requests")) {
            options.bounds.max_requests = try parseNumber(try optionValue(args, &i, arg, "--max-requests"));
        } else if (std.mem.startsWith(u8, arg, "--max-body-bytes=") or std.mem.eql(u8, arg, "--max-body-bytes")) {
            options.bounds.max_body_bytes = try parseNumber(try optionValue(args, &i, arg, "--max-body-bytes"));
        } else if (std.mem.startsWith(u8, arg, "--max-redirects=") or std.mem.eql(u8, arg, "--max-redirects")) {
            options.bounds.max_redirects = try parseNumber(try optionValue(args, &i, arg, "--max-redirects"));
        } else if (std.mem.startsWith(u8, arg, "--timeout-ms=") or std.mem.eql(u8, arg, "--timeout-ms")) {
            options.bounds.timeout_ms = try parseNumber(try optionValue(args, &i, arg, "--timeout-ms"));
        } else if (std.mem.startsWith(u8, arg, "--max-projection-urls=") or std.mem.eql(u8, arg, "--max-projection-urls")) {
            options.bounds.max_projection_urls = try parseNumber(try optionValue(args, &i, arg, "--max-projection-urls"));
        } else {
            return error.UnknownFlag;
        }
    }
    if (options.plan_path.len == 0 or options.inventory_path.len == 0 or
        options.page_url.len == 0 or options.out_path.len == 0 or options.audited_at.len == 0)
    {
        return error.MissingRequiredOption;
    }
    return options;
}

fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(gpa, .unlimited);
}

fn writeFile(io: Io, path: []const u8, bytes: []const u8) !void {
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn run(init: std.process.Init, args: []const []const u8) !u8 {
    const options = parse(args) catch |err| {
        if (err == error.Version) {
            var stdout_buffer: [128]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
            stdout_writer.interface.writeAll(tool_id ++ "\n") catch {};
            stdout_writer.interface.flush() catch {};
            return 0;
        }
        if (err != error.Help) usage();
        return if (err == error.Help) 0 else 2;
    };
    const gpa = init.gpa;
    const plan_bytes = try readFile(init.io, gpa, options.plan_path);
    defer gpa.free(plan_bytes);
    const inventory_bytes = try readFile(init.io, gpa, options.inventory_path);
    defer gpa.free(inventory_bytes);

    var plan = audit.parsePlan(gpa, plan_bytes, options.target) catch |err| {
        std.debug.print("github-pages-audit: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer plan.deinit();
    var inventory = audit.parseInventory(gpa, inventory_bytes, options.target) catch |err| {
        std.debug.print("github-pages-audit: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer inventory.deinit();

    var report = audit.runAudit(
        gpa,
        init.io,
        &plan,
        &inventory,
        plan_bytes,
        inventory_bytes,
        options.page_url,
        .{
            .repository = options.repository,
            .source_commit = options.source_commit,
            .workflow_ref = options.workflow_ref,
            .workflow_sha = options.workflow_sha,
            .run_id = options.run_id,
            .run_attempt = options.run_attempt,
            .deployment_id = options.deployment_id,
            .public_artifact_name = options.public_artifact_name,
            .audited_at = options.audited_at,
        },
        options.bounds,
    ) catch |err| {
        std.debug.print("github-pages-audit: {s}\n", .{@errorName(err)});
        return 2;
    };
    defer report.deinit();
    const evidence = try audit.renderEvidence(gpa, &report);
    defer gpa.free(evidence);
    try writeFile(init.io, options.out_path, evidence);
    std.debug.print(
        "github-pages-audit: {s} ({d} requests, {d} observations) -> {s}\n",
        .{ report.result.name(), report.requests, report.observations.items.len, options.out_path },
    );
    return switch (report.result) {
        .passed, .not_applicable => 0,
        .failed => 1,
        .incomplete => 2,
    };
}

pub fn main(init: std.process.Init) u8 {
    const args = init.minimal.args.toSlice(init.arena.allocator()) catch return 2;
    return run(init, args) catch |err| {
        std.debug.print("github-pages-audit: {s}\n", .{@errorName(err)});
        return 2;
    };
}
