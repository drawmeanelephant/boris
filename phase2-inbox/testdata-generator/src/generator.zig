//! Fixture generation and Boris subprocess evidence.

const std = @import("std");
const barbs = @import("barbs.zig");
const graph = @import("graph.zig");
const manifest = @import("manifest.zig");
const markdown = @import("markdown.zig");

const Io = std.Io;

pub const max_pages: usize = 1_000_000;
pub const max_profile_bytes: usize = 64 * 1024;
pub const max_template_bytes: usize = 1 * 1024 * 1024;

pub const Profile = struct {
    name: []const u8,
    description: []const u8,
    style: markdown.Style,
    include_assets: bool,
    default_barbs: []const barbs.Kind,
    owns_name: bool = false,
    owns_description: bool = false,
    owns_barbs: bool = false,

    pub fn deinit(self: *Profile, allocator: std.mem.Allocator) void {
        if (self.owns_name) allocator.free(self.name);
        if (self.owns_description) allocator.free(self.description);
        if (self.owns_barbs) allocator.free(self.default_barbs);
        self.* = undefined;
    }
};

const readme_barbs = [_]barbs.Kind{};
const nightmare_barbs = [_]barbs.Kind{
    .duplicate_id,
    .self_parent,
    .missing_parent,
    .parent_cycle,
    .unknown_frontmatter,
    .legacy_parent_key,
    .malformed_frontmatter,
    .duplicate_frontmatter_key,
    .broken_wikilink,
    .missing_include,
    .include_cycle,
    .missing_heading_fragment,
    .invalid_utf8,
};
const preserved_barbs = [_]barbs.Kind{.unsafe_markdown_link};
const mild_barbs = [_]barbs.Kind{
    .html_missing_local_route,
    .html_missing_fragment,
    .html_duplicate_id,
    .html_unclosed_structure,
    .artifact_missing,
    .artifact_digest_mismatch,
    .search_stale_title,
    .deployment_owned_extra,
};

pub fn builtinProfile(name: []const u8) ?Profile {
    if (std.mem.eql(u8, name, "readme-realistic-v1")) return .{
        .name = "readme-realistic-v1",
        .description = "README-shaped pages with a rooted guide/article forest and common Markdown constructs",
        .style = .readme,
        .include_assets = true,
        .default_barbs = &readme_barbs,
    };
    if (std.mem.eql(u8, name, "nightmare-v1")) return .{
        .name = "nightmare-v1",
        .description = "A valid baseline carrying one precise failure barb per named mutation locus",
        .style = .reference,
        .include_assets = true,
        .default_barbs = &nightmare_barbs,
    };
    if (std.mem.eql(u8, name, "preserved-edge-v1")) return .{
        .name = "preserved-edge-v1",
        .description = "Boundary cases that should remain literal without turning into compiler failures",
        .style = .compact,
        .include_assets = false,
        .default_barbs = &preserved_barbs,
    };
    if (std.mem.eql(u8, name, "mild-poison-v1")) return .{
        .name = "mild-poison-v1",
        .description = "Mostly valid published output with one precise late-pipeline wound per selected barb",
        .style = .readme,
        .include_assets = true,
        .default_barbs = &mild_barbs,
    };
    return null;
}

pub fn loadProfile(allocator: std.mem.Allocator, io: Io, selector: []const u8) !Profile {
    if (builtinProfile(selector)) |profile| return profile;

    const bytes = readFilePath(io, allocator, selector, max_profile_bytes) catch return error.ProfileNotFound;
    defer allocator.free(bytes);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidProfile;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, bytes, .{
        .duplicate_field_behavior = .@"error",
        .allocate = .alloc_always,
        .max_value_len = 8192,
    }) catch return error.InvalidProfile;
    defer parsed.deinit();

    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidProfile,
    };
    const profile_name = try allocator.dupe(u8, try jsonString(object, "name"));
    errdefer allocator.free(profile_name);
    const description = try allocator.dupe(u8, try jsonString(object, "description"));
    errdefer allocator.free(description);
    const style = try parseStyle(try jsonString(object, "style"));
    const include_assets = jsonBool(object, "includeAssets") orelse true;

    var barb_list: std.ArrayList(barbs.Kind) = .empty;
    if (object.get("barbs")) |value| {
        const values = switch (value) {
            .array => |array| array.items,
            else => return error.InvalidProfile,
        };
        for (values) |item| {
            const name = switch (item) {
                .string => |string| string,
                else => return error.InvalidProfile,
            };
            barb_list.append(allocator, try barbs.parse(name)) catch return error.InvalidProfile;
        }
    }
    const owned_barbs = try barb_list.toOwnedSlice(allocator);
    return .{
        .name = profile_name,
        .description = description,
        .style = style,
        .include_assets = include_assets,
        .default_barbs = owned_barbs,
        .owns_name = true,
        .owns_description = true,
        .owns_barbs = owned_barbs.len > 0,
    };
}

pub const GenerateOptions = struct {
    io: Io,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    pages: usize = 24,
    seed: u64 = 20260801,
    profile_selector: []const u8 = "readme-realistic-v1",
    barb_names: []const []const u8 = &.{},
    theme_path: ?[]const u8 = null,
    template_path: ?[]const u8 = null,
    force: bool = false,
};

pub const GenerateSummary = struct {
    profile: Profile,
    page_count: usize,
    assignments: []barbs.Assignment,
    output_path: []const u8,
};

pub fn generate(options: GenerateOptions) !GenerateSummary {
    if (options.pages == 0 or options.pages > max_pages) return error.InvalidPageCount;

    var profile = try loadProfile(options.allocator, options.io, options.profile_selector);
    errdefer profile.deinit(options.allocator);
    const kinds = try selectBarbs(options.allocator, profile.default_barbs, options.barb_names);
    const owns_kinds = options.barb_names.len > 0;
    defer {
        if (owns_kinds) options.allocator.free(kinds);
    }
    const assignments = try barbs.assign(options.allocator, kinds, options.pages, options.seed);
    errdefer options.allocator.free(assignments);
    if (hasCompileFailure(assignments) and hasPostPublishBarb(assignments)) return error.IncompatibleBarbCombination;

    if (pathExists(options.io, options.output_path)) {
        if (!options.force) return error.OutputExists;
        try deletePath(options.io, options.output_path);
    }
    try ensureDirPath(options.io, options.output_path);
    var fixture = try openDirPath(options.io, options.output_path, .{});
    defer fixture.close(options.io);

    try fixture.createDirPath(options.io, "content/includes");
    try fixture.createDirPath(options.io, "optional-assets/shared");
    try fixture.createDirPath(options.io, "optional-theme/layouts");
    try fixture.createDirPath(options.io, "optional-theme/assets/css");
    try fixture.createDirPath(options.io, "results");

    var inventory = try manifest.Inventory.open(options.io, fixture);
    var inventory_open = true;
    defer {
        if (inventory_open) _ = inventory.close();
    }

    var plan = try graph.GraphPlan.init(options.allocator, options.pages, options.seed);
    defer plan.deinit(options.allocator);
    plan.applyGraphBarbs(assignments);

    try writeIncludes(options.io, fixture, options.allocator, &inventory, assignments);
    try writeAssets(options.io, fixture, &inventory, profile.include_assets);
    const theme_description = try writeTheme(
        options.io,
        fixture,
        options.allocator,
        &inventory,
        options.theme_path,
        hasBarb(assignments, .invalid_theme),
    );
    const template_bytes = if (options.template_path) |path|
        try readFilePath(options.io, options.allocator, path, max_template_bytes)
    else
        null;
    defer if (template_bytes) |bytes| options.allocator.free(bytes);

    var page_index: usize = 0;
    while (page_index < plan.pages.len) : (page_index += 1) {
        try writePage(
            options.io,
            fixture,
            options.allocator,
            &inventory,
            &plan,
            plan.pages[page_index],
            assignments,
            profile,
            options.seed,
            template_bytes,
        );
    }

    const inventory_summary = inventory.close();
    inventory_open = false;
    const expected_hash = try manifest.writeExpected(
        options.io,
        fixture,
        options.allocator,
        profile.name,
        options.seed,
        options.pages,
        assignments,
    );
    const template_description = if (options.template_path) |path| path else "builtin:ast-grammar-v1";
    try manifest.writeManifest(
        options.io,
        fixture,
        options.allocator,
        profile.name,
        profile.description,
        options.seed,
        options.pages,
        plan,
        inventory_summary,
        expected_hash,
        theme_description,
        template_description,
    );

    return .{
        .profile = profile,
        .page_count = options.pages,
        .assignments = assignments,
        .output_path = options.output_path,
    };
}

fn selectBarbs(
    allocator: std.mem.Allocator,
    defaults: []const barbs.Kind,
    names: []const []const u8,
) ![]const barbs.Kind {
    if (names.len == 0) return defaults;
    const selected = try allocator.alloc(barbs.Kind, names.len);
    for (names, 0..) |name, index| selected[index] = try barbs.parse(name);
    return selected;
}

fn writePage(
    io: Io,
    fixture: Io.Dir,
    allocator: std.mem.Allocator,
    inventory: *manifest.Inventory,
    plan: *const graph.GraphPlan,
    page: graph.PagePlan,
    assignments: []const barbs.Assignment,
    profile: Profile,
    seed: u64,
    template_bytes: ?[]const u8,
) !void {
    var page_arena = std.heap.ArenaAllocator.init(allocator);
    defer page_arena.deinit();
    const a = page_arena.allocator();

    var id_buffer: [192]u8 = undefined;
    var source_buffer: [224]u8 = undefined;
    var title_buffer: [192]u8 = undefined;
    const source_path = try graph.GraphPlan.sourcePath(page, &source_buffer);
    const baseline_id = try graph.GraphPlan.id(page, &id_buffer);
    const title = try graph.GraphPlan.title(page, &title_buffer);
    const related = plan.targetForPage(page);
    var related_id_buffer: [192]u8 = undefined;
    var related_source_buffer: [224]u8 = undefined;
    const related_id = try graph.GraphPlan.id(related, &related_id_buffer);
    const related_source = try plan.relativeSourcePath(page, related, &related_source_buffer);

    const parent_id = try parentValue(a, plan, page);
    const id_value = if (hasBarbForPage(assignments, page.index, .duplicate_id))
        try duplicateId(a, plan, page)
    else
        baseline_id;

    var output = std.Io.Writer.Allocating.init(a);
    try writeFrontmatter(&output.writer, page, id_value, title, parent_id, assignments);

    const context = markdown.Context{
        .page = page,
        .id = id_value,
        .title = title,
        .parent = parent_id,
        .related_id = related_id,
        .related_source = related_source,
        .seed = barbs.mix(seed, page.index),
        .has_image = page.index == 0,
    };
    if (template_bytes) |template| {
        var document = try markdown.parseTemplate(a, template, .{
            .id = id_value,
            .title = title,
            .parent = parent_id orelse "",
            .index = page.index,
            .seed = context.seed,
            .related = related_id,
            .include = "{{include includes/common.md}}",
        });
        defer document.deinit(a);
        try markdown.render(document, &output.writer);
    } else {
        var document = try markdown.synthetic(a, context, profile.style);
        defer document.deinit(a);
        try markdown.render(document, &output.writer);
    }

    try appendBodyBarbs(&output.writer, page, baseline_id, related_id, assignments);
    const page_bytes = try output.toOwnedSlice();
    defer a.free(page_bytes);

    if (std.fs.path.dirname(source_path)) |parent| try fixture.createDirPath(io, std.fmt.allocPrint(a, "content/{s}", .{parent}) catch return error.OutOfMemory);
    const content_path = try std.fmt.allocPrint(a, "content/{s}", .{source_path});
    try fixture.writeFile(io, .{ .sub_path = content_path, .data = page_bytes });
    try inventory.add(allocator, content_path, "page", page_bytes, id_value, planRole(plan, page), parent_id);
}

fn writeFrontmatter(
    writer: *std.Io.Writer,
    page: graph.PagePlan,
    id_value: []const u8,
    title: []const u8,
    parent: ?[]const u8,
    assignments: []const barbs.Assignment,
) !void {
    if (hasBarbForPage(assignments, page.index, .malformed_frontmatter)) {
        try writer.print("---\nid: {s}\ntitle: {s}\nthis-is-not-a-field\n", .{ id_value, title });
        return;
    }

    try writer.writeAll("---\n");
    try writer.print("id: {s}\n", .{id_value});
    try writer.print("title: {s}\n", .{title});
    if (hasBarbForPage(assignments, page.index, .legacy_parent_key)) {
        try writer.print("parentEntry: {s}\n", .{parent orelse "legacy-parent"});
    } else if (parent) |value| {
        try writer.print("parent: {s}\n", .{value});
    }
    try writer.writeAll("status: published\ntags: [generated, fixture]\n");
    if (hasBarbForPage(assignments, page.index, .unknown_frontmatter)) {
        try writer.writeAll("layout: hostile\n");
    }
    try writer.print("summary: Generated page {d} for deterministic fixture coverage\n", .{page.index});
    if (hasBarbForPage(assignments, page.index, .duplicate_frontmatter_key)) {
        try writer.writeAll("title: Duplicate title\n");
    }
    try writer.writeAll("---\n");
}

fn appendBodyBarbs(
    writer: *std.Io.Writer,
    page: graph.PagePlan,
    baseline_id: []const u8,
    related_id: []const u8,
    assignments: []const barbs.Assignment,
) !void {
    if (hasBarbForPage(assignments, page.index, .broken_wikilink)) try writer.writeAll("\n[[missing/fixture-target]]\n");
    if (hasBarbForPage(assignments, page.index, .missing_heading_fragment)) try writer.print("\n[[{s}#does-not-exist]]\n", .{related_id});
    if (hasBarbForPage(assignments, page.index, .unsafe_markdown_link)) try writer.writeAll("\n[escape](../../../../outside.md)\n");
    if (hasBarbForPage(assignments, page.index, .invalid_utf8)) {
        try writer.writeAll("\ninvalid utf8 follows: ");
        try writer.writeByte(0xff);
        try writer.writeByte('\n');
    }
    _ = baseline_id;
}

fn parentValue(allocator: std.mem.Allocator, plan: *const graph.GraphPlan, page: graph.PagePlan) !?[]const u8 {
    const parent_index = page.parent_index orelse return null;
    if (parent_index >= plan.pages.len) return @as(?[]const u8, try allocator.dupe(u8, "missing/fixture-parent"));
    var buffer: [192]u8 = undefined;
    return @as(?[]const u8, try allocator.dupe(u8, try graph.GraphPlan.id(plan.pages[parent_index], &buffer)));
}

fn duplicateId(allocator: std.mem.Allocator, plan: *const graph.GraphPlan, page: graph.PagePlan) ![]const u8 {
    const other = if (page.index == 0 and plan.pages.len > 1) plan.pages[1] else plan.pages[0];
    var buffer: [192]u8 = undefined;
    return allocator.dupe(u8, try graph.GraphPlan.id(other, &buffer));
}

fn planRole(plan: *const graph.GraphPlan, page: graph.PagePlan) []const u8 {
    _ = plan;
    return graph.GraphPlan.role(page);
}

fn hasBarb(assignments: []const barbs.Assignment, kind: barbs.Kind) bool {
    for (assignments) |assignment| if (assignment.kind == kind) return true;
    return false;
}

fn hasCompileFailure(assignments: []const barbs.Assignment) bool {
    for (assignments) |assignment| {
        if (barbs.behavior(assignment.kind) == .compile_failure) return true;
    }
    return false;
}

fn hasPostPublishBarb(assignments: []const barbs.Assignment) bool {
    for (assignments) |assignment| {
        if (barbs.isPostPublish(assignment.kind)) return true;
    }
    return false;
}

fn hasBarbForPage(assignments: []const barbs.Assignment, page_index: usize, kind: barbs.Kind) bool {
    for (assignments) |assignment| {
        if (assignment.kind == kind and assignment.target == page_index) return true;
    }
    return false;
}

fn writeIncludes(
    io: Io,
    fixture: Io.Dir,
    allocator: std.mem.Allocator,
    inventory: *manifest.Inventory,
    assignments: []const barbs.Assignment,
) !void {
    var common = std.Io.Writer.Allocating.init(allocator);
    defer common.deinit();
    try common.writer.writeAll("Shared fixture fragment.\n\n{{include includes/shared.md}}\n");
    if (hasBarb(assignments, .missing_include)) try common.writer.writeAll("\n{{include includes/missing.md}}\n");
    try writeTracked(io, fixture, allocator, inventory, "content/includes/common.md", "include", common.writer.buffered(), null);

    var shared = std.Io.Writer.Allocating.init(allocator);
    defer shared.deinit();
    try shared.writer.writeAll("A stable include target with a [[index]] reference.\n");
    if (hasBarb(assignments, .include_cycle)) try shared.writer.writeAll("{{include includes/common.md}}\n");
    try writeTracked(io, fixture, allocator, inventory, "content/includes/shared.md", "include", shared.writer.buffered(), null);
    try writeTracked(io, fixture, allocator, inventory, "content/includes/in-code-fence.md", "include", "This must remain inside a fence.\n", null);
}

fn writeAssets(io: Io, fixture: Io.Dir, inventory: *manifest.Inventory, include_assets: bool) !void {
    if (!include_assets) return;
    try fixture.createDirPath(io, "content/index.assets");
    try writeTracked(io, fixture, std.heap.page_allocator, inventory, "content/index.assets/diagram.svg", "asset", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 4 4\"><path d=\"M0 0h4v4H0z\"/></svg>\n", null);
    try writeTracked(io, fixture, std.heap.page_allocator, inventory, "optional-assets/shared/fixture.svg", "asset", "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 8 8\"><circle cx=\"4\" cy=\"4\" r=\"3\"/></svg>\n", null);
}

fn writeTheme(
    io: Io,
    fixture: Io.Dir,
    allocator: std.mem.Allocator,
    inventory: *manifest.Inventory,
    external_path: ?[]const u8,
    invalid: bool,
) ![]const u8 {
    if (external_path != null and !invalid) {
        try copyTree(io, allocator, external_path.?, fixture, inventory, "optional-theme");
        return external_path.?;
    }

    const layout = if (invalid)
        "<!doctype html>\n<html><body><main>{{title}}</main></body></html>\n"
    else
        "<!doctype html>\n<html lang=\"en\"><head><meta charset=\"utf-8\"><title>{{title}}</title><link rel=\"stylesheet\" href=\"{{asset-url assets/css/docs.css}}\"></head><body><nav>{{nav}}</nav><main>{{content}}</main><footer>{{footer}}</footer></body></html>\n";
    try writeTracked(io, fixture, allocator, inventory, "optional-theme/layouts/main.html", "theme", layout, null);
    try writeTracked(io, fixture, allocator, inventory, "optional-theme/footer.html", "theme", "<small>Generated by boris-testdata.</small>\n", null);
    try writeTracked(io, fixture, allocator, inventory, "optional-theme/assets/css/docs.css", "theme", "body{font-family:system-ui,sans-serif;max-width:70rem;margin:auto;padding:2rem}main{line-height:1.6}nav{border-bottom:1px solid #ccc;padding-bottom:1rem}\n", null);
    return if (invalid) "builtin:hostile-missing-content" else "builtin:ideal-v1";
}

fn writeTracked(
    io: Io,
    fixture: Io.Dir,
    allocator: std.mem.Allocator,
    inventory: *manifest.Inventory,
    path: []const u8,
    kind: []const u8,
    bytes: []const u8,
    id: ?[]const u8,
) !void {
    if (std.fs.path.dirname(path)) |parent| try fixture.createDirPath(io, parent);
    try fixture.writeFile(io, .{ .sub_path = path, .data = bytes });
    try inventory.add(allocator, path, kind, bytes, id, null, null);
}

fn copyTree(io: Io, allocator: std.mem.Allocator, source_path: []const u8, destination: Io.Dir, inventory: *manifest.Inventory, destination_root: []const u8) !void {
    var source = try openDirPath(io, source_path, .{ .iterate = true });
    defer source.close(io);
    try copyTreeDir(io, allocator, source, destination, inventory, destination_root);
}

fn copyTreeDir(io: Io, allocator: std.mem.Allocator, source: Io.Dir, destination: Io.Dir, inventory: *manifest.Inventory, relative_root: []const u8) !void {
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }
    var iterator = source.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.kind != .file and entry.kind != .directory) return error.UnsafeTheme;
        try names.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.sort.heap([]u8, names.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    for (names.items) |name| {
        const entry = try source.statFile(io, name, .{ .follow_symlinks = false });
        const destination_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ relative_root, name });
        defer allocator.free(destination_path);
        if (entry.kind == .directory) {
            try destination.createDirPath(io, destination_path);
            var child = try source.openDir(io, name, .{ .iterate = true });
            defer child.close(io);
            try copyTreeDir(io, allocator, child, destination, inventory, destination_path);
        } else {
            var file = try source.openFile(io, name, .{ .follow_symlinks = false });
            defer file.close(io);
            var reader = file.reader(io, &.{});
            const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
            defer allocator.free(bytes);
            try writeTracked(io, destination, allocator, inventory, destination_path, "theme", bytes, null);
        }
    }
}

pub const RunOptions = struct {
    io: Io,
    allocator: std.mem.Allocator,
    fixture_path: []const u8,
    boris_path: []const u8,
};

pub fn runFixture(options: RunOptions) !void {
    const cwd_path = try std.process.currentPathAlloc(options.io, options.allocator);
    defer options.allocator.free(cwd_path);
    const fixture_abs = try std.fs.path.resolve(options.allocator, &.{ cwd_path, options.fixture_path });
    defer options.allocator.free(fixture_abs);
    const parent = std.fs.path.dirname(fixture_abs) orelse return error.InvalidFixture;
    const base = std.fs.path.basename(fixture_abs);
    const boris_abs = try std.fs.path.resolve(options.allocator, &.{ cwd_path, options.boris_path });
    defer options.allocator.free(boris_abs);

    const input_arg = try std.fmt.allocPrint(options.allocator, "{s}/content", .{base});
    defer options.allocator.free(input_arg);
    const html_arg = try std.fmt.allocPrint(options.allocator, "{s}/results/boris-output", .{base});
    defer options.allocator.free(html_arg);
    const theme_arg = try std.fmt.allocPrint(options.allocator, "{s}/optional-theme", .{base});
    defer options.allocator.free(theme_arg);

    var expected = try readExpectedFixture(options.io, options.allocator, fixture_abs);
    defer expected.deinit(options.allocator);
    const expected_code = expected.exit_code;
    const start = Io.Clock.awake.now(options.io);
    const result = try std.process.run(options.allocator, options.io, .{
        .argv = &.{ boris_abs, "--input", input_arg, "--theme", theme_arg, "--html-dir", html_arg, "--quiet" },
        .cwd = .{ .path = parent },
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
    });
    defer options.allocator.free(result.stdout);
    defer options.allocator.free(result.stderr);
    const elapsed_ns = start.untilNow(options.io, .awake).nanoseconds;
    const actual_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };

    const binary = try readFileAbsolute(options.io, options.allocator, boris_abs, 256 * 1024 * 1024);
    defer options.allocator.free(binary);
    const binary_hash = manifest.sha256Hex(binary);
    const baseline_tree = try hashTree(options.io, options.allocator, fixture_abs, "results/boris-output");
    const publication = try writePublicationInventory(options.io, options.allocator, fixture_abs, "results/boris-output");

    var plan = try graph.GraphPlan.init(options.allocator, expected.page_count, expected.seed);
    defer plan.deinit(options.allocator);
    if (actual_code == expected_code and expected_code == 0) {
        try applyPostPublishBarbs(options.io, options.allocator, fixture_abs, &plan, expected.assignments);
    }
    const output_tree = try hashTree(options.io, options.allocator, fixture_abs, "results/boris-output");
    const passed = actual_code == expected_code;

    var fixture = try Io.Dir.openDirAbsolute(options.io, fixture_abs, .{});
    defer fixture.close(options.io);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(options.allocator);
    try output.appendSlice(options.allocator, "{\n  \"schemaVersion\":\"boris-testdata-run/2\",\n  \"expectedExitCode\":");
    try appendDecimal(&output, options.allocator, expected_code);
    try output.appendSlice(options.allocator, ",\n  \"actualExitCode\":");
    try appendDecimal(&output, options.allocator, actual_code);
    try output.appendSlice(options.allocator, ",\n  \"passed\":");
    try output.appendSlice(options.allocator, if (passed) "true" else "false");
    try output.appendSlice(options.allocator, ",\n  \"elapsedNs\":");
    try appendDecimal(&output, options.allocator, elapsed_ns);
    try output.appendSlice(options.allocator, ",\n  \"binarySha256\":");
    try manifest.appendJsonString(&output, options.allocator, &binary_hash);
    try output.appendSlice(options.allocator, ",\n  \"baselineOutputTreeSha256\":");
    try manifest.appendJsonString(&output, options.allocator, &baseline_tree.hash);
    try output.appendSlice(options.allocator, ",\n  \"baselineOutputFileCount\":");
    try appendDecimal(&output, options.allocator, baseline_tree.file_count);
    try output.appendSlice(options.allocator, ",\n  \"outputTreeSha256\":");
    try manifest.appendJsonString(&output, options.allocator, &output_tree.hash);
    try output.appendSlice(options.allocator, ",\n  \"outputFileCount\":");
    try appendDecimal(&output, options.allocator, output_tree.file_count);
    try output.appendSlice(options.allocator, ",\n  \"publicationInventorySha256\":");
    try manifest.appendJsonString(&output, options.allocator, &publication.sha256);
    try output.appendSlice(options.allocator, ",\n  \"publicationInventoryFileCount\":");
    try appendDecimal(&output, options.allocator, publication.count);
    try output.appendSlice(options.allocator, ",\n  \"postPublishBarbsApplied\":");
    try appendDecimal(&output, options.allocator, countPostPublishBarbs(expected.assignments));
    try output.appendSlice(options.allocator, ",\n  \"stdout\":");
    try manifest.appendJsonString(&output, options.allocator, result.stdout);
    try output.appendSlice(options.allocator, ",\n  \"stderr\":");
    try manifest.appendJsonString(&output, options.allocator, result.stderr);
    try output.appendSlice(options.allocator, "\n}\n");
    try fixture.writeFile(options.io, .{ .sub_path = "results/run.json", .data = output.items });

    if (!passed) return error.BorisExpectationMismatch;
}

pub fn repairFixture(options: RunOptions) !void {
    const cwd_path = try std.process.currentPathAlloc(options.io, options.allocator);
    defer options.allocator.free(cwd_path);
    const fixture_abs = try std.fs.path.resolve(options.allocator, &.{ cwd_path, options.fixture_path });
    defer options.allocator.free(fixture_abs);
    const parent = std.fs.path.dirname(fixture_abs) orelse return error.InvalidFixture;
    const base = std.fs.path.basename(fixture_abs);
    const boris_abs = try std.fs.path.resolve(options.allocator, &.{ cwd_path, options.boris_path });
    defer options.allocator.free(boris_abs);

    var expected = try readExpectedFixture(options.io, options.allocator, fixture_abs);
    defer expected.deinit(options.allocator);
    if (hasCompileFailure(expected.assignments)) return error.InvalidFixture;

    const repaired_abs = try std.fs.path.join(options.allocator, &.{ fixture_abs, "results/repaired-output" });
    defer options.allocator.free(repaired_abs);
    if (pathExists(options.io, repaired_abs)) try deletePath(options.io, repaired_abs);

    const input_arg = try std.fmt.allocPrint(options.allocator, "{s}/content", .{base});
    defer options.allocator.free(input_arg);
    const html_arg = try std.fmt.allocPrint(options.allocator, "{s}/results/repaired-output", .{base});
    defer options.allocator.free(html_arg);
    const theme_arg = try std.fmt.allocPrint(options.allocator, "{s}/optional-theme", .{base});
    defer options.allocator.free(theme_arg);

    const result = try std.process.run(options.allocator, options.io, .{
        .argv = &.{ boris_abs, "--input", input_arg, "--theme", theme_arg, "--html-dir", html_arg, "--quiet" },
        .cwd = .{ .path = parent },
        .stdout_limit = .limited(2 * 1024 * 1024),
        .stderr_limit = .limited(2 * 1024 * 1024),
    });
    defer options.allocator.free(result.stdout);
    defer options.allocator.free(result.stderr);
    const actual_code: u8 = switch (result.term) {
        .exited => |code| code,
        else => 255,
    };
    const output_tree = try hashTree(options.io, options.allocator, fixture_abs, "results/repaired-output");
    const passed = actual_code == expected.exit_code;

    var fixture = try Io.Dir.openDirAbsolute(options.io, fixture_abs, .{});
    defer fixture.close(options.io);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(options.allocator);
    try output.appendSlice(options.allocator, "{\n  \"schemaVersion\":\"boris-testdata-repair/1\",\n  \"expectedExitCode\":");
    try appendDecimal(&output, options.allocator, expected.exit_code);
    try output.appendSlice(options.allocator, ",\n  \"actualExitCode\":");
    try appendDecimal(&output, options.allocator, actual_code);
    try output.appendSlice(options.allocator, ",\n  \"passed\":");
    try output.appendSlice(options.allocator, if (passed) "true" else "false");
    try output.appendSlice(options.allocator, ",\n  \"outputTreeSha256\":");
    try manifest.appendJsonString(&output, options.allocator, &output_tree.hash);
    try output.appendSlice(options.allocator, ",\n  \"outputFileCount\":");
    try appendDecimal(&output, options.allocator, output_tree.file_count);
    try output.appendSlice(options.allocator, ",\n  \"stdout\":");
    try manifest.appendJsonString(&output, options.allocator, result.stdout);
    try output.appendSlice(options.allocator, ",\n  \"stderr\":");
    try manifest.appendJsonString(&output, options.allocator, result.stderr);
    try output.appendSlice(options.allocator, "\n}\n");
    try fixture.writeFile(options.io, .{ .sub_path = "results/repair.json", .data = output.items });

    if (!passed) return error.BorisExpectationMismatch;
}

const TreeHash = struct { hash: manifest.HashText, file_count: usize };

fn hashTree(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8, relative: []const u8) !TreeHash {
    var root = try Io.Dir.openDirAbsolute(io, fixture_abs, .{ .iterate = true });
    defer root.close(io);
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    var output = root.openDir(io, relative, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            var empty_hasher = std.crypto.hash.sha2.Sha256.init(.{});
            var empty_digest: [32]u8 = undefined;
            empty_hasher.final(&empty_digest);
            return .{ .hash = manifest.digestToHex(empty_digest), .file_count = 0 };
        },
        else => return err,
    };
    defer output.close(io);
    try collectFiles(io, allocator, output, "", &files);
    std.sort.heap([]u8, files.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    for (files.items) |path| {
        var file = try output.openFile(io, path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(bytes);
        hasher.update(path);
        hasher.update("\n");
        hasher.update(bytes);
        hasher.update("\n");
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .hash = manifest.digestToHex(digest), .file_count = files.items.len };
}

fn collectFiles(io: Io, allocator: std.mem.Allocator, directory: Io.Dir, prefix: []const u8, files: *std.ArrayList([]u8)) !void {
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        const path = if (prefix.len == 0)
            try allocator.dupe(u8, entry.name)
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name });
        if (entry.kind == .directory) {
            var child = try directory.openDir(io, entry.name, .{ .iterate = true });
            defer child.close(io);
            try collectFiles(io, allocator, child, path, files);
            allocator.free(path);
        } else if (entry.kind == .file) {
            try files.append(allocator, path);
        } else {
            allocator.free(path);
            return error.UnsafeOutput;
        }
    }
}

const ExpectedFixture = struct {
    exit_code: u8,
    seed: u64,
    page_count: usize,
    assignments: []barbs.Assignment,

    fn deinit(self: *ExpectedFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.assignments);
        self.* = undefined;
    }
};

fn readExpectedFixture(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8) !ExpectedFixture {
    const expected_path = try std.fs.path.join(allocator, &.{ fixture_abs, "expected.json" });
    defer allocator.free(expected_path);
    const bytes = try readFileAbsolute(io, allocator, expected_path, 256 * 1024);
    defer allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
    defer parsed.deinit();
    const object = switch (parsed.value) {
        .object => |value| value,
        else => return error.InvalidFixture,
    };
    const seed_value = switch (object.get("seed") orelse return error.InvalidFixture) {
        .integer => |seed| seed,
        else => return error.InvalidFixture,
    };
    const page_count_value = switch (object.get("pageCount") orelse return error.InvalidFixture) {
        .integer => |count| count,
        else => return error.InvalidFixture,
    };
    if (seed_value < 0 or page_count_value <= 0) return error.InvalidFixture;
    const run = switch (object.get("run") orelse return error.InvalidFixture) {
        .object => |value| value,
        else => return error.InvalidFixture,
    };
    const value = switch (run.get("expectedExitCode") orelse return error.InvalidFixture) {
        .integer => |code| code,
        else => return error.InvalidFixture,
    };
    if (value < 0 or value > 255) return error.InvalidFixture;

    const values = switch (object.get("barbs") orelse return error.InvalidFixture) {
        .array => |array| array.items,
        else => return error.InvalidFixture,
    };
    var assignments: std.ArrayList(barbs.Assignment) = .empty;
    errdefer assignments.deinit(allocator);
    for (values) |item| {
        const barb_object = switch (item) {
            .object => |barb_value| barb_value,
            else => return error.InvalidFixture,
        };
        const name_value = switch (barb_object.get("name") orelse return error.InvalidFixture) {
            .string => |name| name,
            else => return error.InvalidFixture,
        };
        const target_value = switch (barb_object.get("targetIndex") orelse return error.InvalidFixture) {
            .integer => |target| target,
            else => return error.InvalidFixture,
        };
        if (target_value < 0) return error.InvalidFixture;
        const secondary_value = switch (barb_object.get("secondaryIndex") orelse return error.InvalidFixture) {
            .null => null,
            .integer => |secondary| if (secondary < 0) return error.InvalidFixture else @as(?usize, @intCast(secondary)),
            else => return error.InvalidFixture,
        };
        try assignments.append(allocator, .{
            .kind = barbs.parse(name_value) catch return error.InvalidFixture,
            .target = @intCast(target_value),
            .secondary = secondary_value,
        });
    }
    return .{
        .exit_code = @intCast(value),
        .seed = @intCast(seed_value),
        .page_count = @intCast(page_count_value),
        .assignments = try assignments.toOwnedSlice(allocator),
    };
}

fn countPostPublishBarbs(assignments: []const barbs.Assignment) usize {
    var count: usize = 0;
    for (assignments) |assignment| {
        if (barbs.isPostPublish(assignment.kind)) count += 1;
    }
    return count;
}

fn writePublicationInventory(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    output_relative: []const u8,
) !manifest.InventorySummary {
    var fixture = try Io.Dir.openDirAbsolute(io, fixture_abs, .{ .iterate = true });
    defer fixture.close(io);
    var results = try fixture.openDir(io, "results", .{});
    defer results.close(io);

    var inventory = try manifest.Inventory.openNamed(io, results, "publication.jsonl");
    var inventory_open = true;
    defer {
        if (inventory_open) _ = inventory.close();
    }

    var output = fixture.openDir(io, output_relative, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const summary = inventory.close();
            inventory_open = false;
            try manifest.writePublicationSummary(io, results, allocator, output_relative, summary);
            return summary;
        },
        else => return err,
    };
    defer output.close(io);

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    try collectFiles(io, allocator, output, "", &files);
    std.sort.heap([]u8, files.items, {}, struct {
        fn lessThan(_: void, left: []u8, right: []u8) bool {
            return std.mem.lessThan(u8, left, right);
        }
    }.lessThan);

    for (files.items) |path| {
        var file = try output.openFile(io, path, .{});
        defer file.close(io);
        var reader = file.reader(io, &.{});
        const bytes = try reader.interface.allocRemaining(allocator, .unlimited);
        defer allocator.free(bytes);
        try inventory.add(allocator, path, publicationKind(path), bytes, null, null, null);
    }
    const summary = inventory.close();
    inventory_open = false;
    try manifest.writePublicationSummary(io, results, allocator, output_relative, summary);
    return summary;
}

fn publicationKind(path: []const u8) []const u8 {
    if (std.mem.endsWith(u8, path, ".html")) return "html-page";
    if (std.mem.startsWith(u8, path, "_boris/search/")) return "derived-search";
    if (std.mem.startsWith(u8, path, "assets/") or std.mem.indexOf(u8, path, ".assets/") != null) return "asset";
    return "published-artifact";
}

fn applyPostPublishBarbs(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    plan: *const graph.GraphPlan,
    assignments: []const barbs.Assignment,
) !void {
    var pass: usize = 0;
    while (pass < 2) : (pass += 1) {
        for (assignments) |assignment| {
            if (!barbs.isPostPublish(assignment.kind)) continue;
            if ((pass == 0 and assignment.kind == .artifact_missing) or
                (pass == 1 and assignment.kind != .artifact_missing)) continue;
            if (assignment.target >= plan.pages.len) return error.InvalidFixture;
            switch (assignment.kind) {
                .html_missing_local_route,
                .html_missing_fragment,
                .html_duplicate_id,
                .html_unclosed_structure,
                => try mutateHtmlOutput(io, allocator, fixture_abs, plan.pages[assignment.target], assignment.kind),
                .artifact_missing => {
                    const path = try artifactPath(io, allocator, fixture_abs);
                    defer allocator.free(path);
                    try deleteOutputPath(io, allocator, fixture_abs, path);
                },
                .artifact_digest_mismatch => {
                    const path = try artifactPath(io, allocator, fixture_abs);
                    defer allocator.free(path);
                    try mutateDigestOutput(io, allocator, fixture_abs, path);
                },
                .search_stale_title => try mutateSearchTitle(io, allocator, fixture_abs),
                .deployment_owned_extra => try writeDeploymentOwnedExtra(io, fixture_abs),
                else => unreachable,
            }
        }
    }
}

fn outputPagePath(allocator: std.mem.Allocator, page: graph.PagePlan) ![]u8 {
    var id_buffer: [192]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{s}.html", .{try graph.GraphPlan.id(page, &id_buffer)});
}

fn artifactPath(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8) ![]u8 {
    const search = try std.fs.path.join(allocator, &.{ fixture_abs, "results/boris-output/_boris/search/search-index.json" });
    defer allocator.free(search);
    if (pathExists(io, search)) return allocator.dupe(u8, "_boris/search/search-index.json");
    const preferred = try std.fs.path.join(allocator, &.{ fixture_abs, "results/boris-output/assets/css/docs.css" });
    defer allocator.free(preferred);
    if (pathExists(io, preferred)) return allocator.dupe(u8, "assets/css/docs.css");
    return allocator.dupe(u8, "index.html");
}

fn readOutputPath(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8, relative: []const u8) ![]u8 {
    const absolute = try std.fs.path.join(allocator, &.{ fixture_abs, "results/boris-output", relative });
    defer allocator.free(absolute);
    return readFileAbsolute(io, allocator, absolute, 256 * 1024 * 1024);
}

fn writeOutputPath(io: Io, fixture_abs: []const u8, relative: []const u8, bytes: []const u8) !void {
    var fixture = try Io.Dir.openDirAbsolute(io, fixture_abs, .{});
    defer fixture.close(io);
    var path_buffer: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "results/boris-output/{s}", .{relative});
    try fixture.writeFile(io, .{ .sub_path = path, .data = bytes });
}

fn mutateHtmlOutput(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    page: graph.PagePlan,
    kind: barbs.Kind,
) !void {
    const path = try outputPagePath(allocator, page);
    defer allocator.free(path);
    const original = try readOutputPath(io, allocator, fixture_abs, path);
    defer allocator.free(original);
    const close = std.mem.indexOf(u8, original, "</main>") orelse std.mem.indexOf(u8, original, "</body>") orelse return error.InvalidFixture;

    var insertion: std.ArrayList(u8) = .empty;
    defer insertion.deinit(allocator);
    switch (kind) {
        .html_missing_local_route => try insertion.appendSlice(allocator, "<p><a href=\"missing/boris-testdata-route.html\">poisoned missing route</a></p>\n"),
        .html_missing_fragment => {
            try insertion.appendSlice(allocator, "<p><a href=\"");
            const depth = std.mem.count(u8, path, "/");
            var i: usize = 0;
            while (i < depth) : (i += 1) try insertion.appendSlice(allocator, "../");
            try insertion.appendSlice(allocator, "index.html#boris-testdata-missing-fragment\">poisoned missing fragment</a></p>\n");
        },
        .html_duplicate_id => try insertion.appendSlice(allocator, "<span id=\"boris-testdata-duplicate-id\"></span><span id=\"boris-testdata-duplicate-id\"></span>\n"),
        .html_unclosed_structure => try insertion.appendSlice(allocator, "<script>poisoned unclosed structure\n"),
        else => unreachable,
    }

    var mutated: std.ArrayList(u8) = .empty;
    defer mutated.deinit(allocator);
    try mutated.appendSlice(allocator, original[0..close]);
    try mutated.appendSlice(allocator, insertion.items);
    try mutated.appendSlice(allocator, original[close..]);
    try writeOutputPath(io, fixture_abs, path, mutated.items);
}

fn mutateDigestOutput(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8, path: []const u8) !void {
    const original = try readOutputPath(io, allocator, fixture_abs, path);
    defer allocator.free(original);
    var mutated = try allocator.dupe(u8, original);
    defer allocator.free(mutated);
    if (std.mem.indexOf(u8, mutated, "Generated")) |marker| {
        mutated[marker] = 'X';
    } else {
        var changed = false;
        for (mutated, 0..) |byte, index| {
            if (std.ascii.isAlphabetic(byte)) {
                mutated[index] = if (byte == 'z') 'y' else byte + 1;
                changed = true;
                break;
            }
        }
        if (!changed) return error.InvalidFixture;
    }
    try writeOutputPath(io, fixture_abs, path, mutated);
}

fn mutateSearchTitle(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8) !void {
    const path = "_boris/search/search-index.json";
    const original = try readOutputPath(io, allocator, fixture_abs, path);
    defer allocator.free(original);
    const marker = "\"title\": \"";
    const start = std.mem.indexOf(u8, original, marker) orelse return error.InvalidFixture;
    const value_start = start + marker.len;
    const value_end = std.mem.indexOfScalarPos(u8, original, value_start, '"') orelse return error.InvalidFixture;
    var mutated: std.ArrayList(u8) = .empty;
    defer mutated.deinit(allocator);
    try mutated.appendSlice(allocator, original[0..value_start]);
    try mutated.appendSlice(allocator, "stale title from old publication");
    try mutated.appendSlice(allocator, original[value_end..]);
    try writeOutputPath(io, fixture_abs, path, mutated.items);
}

fn writeDeploymentOwnedExtra(io: Io, fixture_abs: []const u8) !void {
    try writeOutputPath(io, fixture_abs, "robots.txt", "User-agent: *\nDisallow:\n");
}

fn deleteOutputPath(io: Io, allocator: std.mem.Allocator, fixture_abs: []const u8, relative: []const u8) !void {
    const absolute = try std.fs.path.join(allocator, &.{ fixture_abs, "results/boris-output", relative });
    defer allocator.free(absolute);
    try deletePath(io, absolute);
}

fn jsonString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (object.get(key) orelse return error.InvalidProfile) {
        .string => |value| value,
        else => error.InvalidProfile,
    };
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    return switch (object.get(key) orelse return null) {
        .bool => |value| value,
        else => null,
    };
}

fn parseStyle(value: []const u8) !markdown.Style {
    if (std.mem.eql(u8, value, "readme")) return .readme;
    if (std.mem.eql(u8, value, "reference")) return .reference;
    if (std.mem.eql(u8, value, "compact")) return .compact;
    return error.InvalidProfile;
}

fn pathExists(io: Io, path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) {
        Io.Dir.accessAbsolute(io, path, .{}) catch return false;
    } else {
        Io.Dir.cwd().access(io, path, .{}) catch return false;
    }
    return true;
}

fn ensureDirPath(io: Io, path: []const u8) !void {
    if (std.fs.path.isAbsolute(path)) {
        try Io.Dir.cwd().createDirPath(io, path);
    } else try Io.Dir.cwd().createDirPath(io, path);
}

fn deletePath(io: Io, path: []const u8) !void {
    if (!std.fs.path.isAbsolute(path)) return Io.Dir.cwd().deleteTree(io, path);
    const parent_path = std.fs.path.dirname(path) orelse return error.InvalidOutputPath;
    const base = std.fs.path.basename(path);
    var parent = try Io.Dir.openDirAbsolute(io, parent_path, .{});
    defer parent.close(io);
    try parent.deleteTree(io, base);
}

fn openDirPath(io: Io, path: []const u8, options: Io.Dir.OpenOptions) !Io.Dir {
    if (std.fs.path.isAbsolute(path)) return Io.Dir.openDirAbsolute(io, path, options);
    return Io.Dir.cwd().openDir(io, path, options);
}

fn readFilePath(io: Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    if (std.fs.path.isAbsolute(path)) return readFileAbsolute(io, allocator, path, limit);
    var file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

fn readFileAbsolute(io: Io, allocator: std.mem.Allocator, path: []const u8, limit: usize) ![]u8 {
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(limit));
}

fn appendDecimal(buffer: *std.ArrayList(u8), allocator: std.mem.Allocator, value: anytype) !void {
    const text = try std.fmt.allocPrint(allocator, "{d}", .{value});
    defer allocator.free(text);
    try buffer.appendSlice(allocator, text);
}

test "builtin profiles expose ideal, nightmare, and preserved cases" {
    try std.testing.expect(builtinProfile("readme-realistic-v1") != null);
    try std.testing.expect(builtinProfile("nightmare-v1").?.default_barbs.len > 5);
    try std.testing.expectEqual(@as(usize, 1), builtinProfile("preserved-edge-v1").?.default_barbs.len);
    try std.testing.expectEqual(@as(usize, 8), builtinProfile("mild-poison-v1").?.default_barbs.len);
}
