//! Fixture generation and Boris subprocess evidence.

const std = @import("std");
const barbs = @import("barbs.zig");
const graph = @import("graph.zig");
const manifest = @import("manifest.zig");
const markdown = @import("markdown.zig");

const Io = std.Io;

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
    if (options.pages == 0) return error.InvalidPageCount;

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
        .has_image = profile.include_assets and page.index == 0,
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
    const output_abs = try std.fs.path.join(options.allocator, &.{ fixture_abs, "results/boris-output" });
    defer options.allocator.free(output_abs);
    if (pathExists(options.io, output_abs)) try deletePath(options.io, output_abs);

    var expected = try readExpectedFixture(options.io, options.allocator, fixture_abs);
    defer expected.deinit(options.allocator);
    const expected_code = expected.exit_code;
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

    const binary = try readFileAbsolute(options.io, options.allocator, boris_abs, 256 * 1024 * 1024);
    defer options.allocator.free(binary);
    const binary_hash = manifest.sha256Hex(binary);
    const baseline_tree = try hashTree(options.io, options.allocator, fixture_abs, "results/boris-output");
    var artifact_inventory: ?ArtifactInventory = null;
    defer if (artifact_inventory) |*inventory| inventory.deinit(options.allocator);
    if (actual_code == expected_code and expected_code == 0) {
        artifact_inventory = try readArtifactInventory(options.io, options.allocator, fixture_abs, expected.assignments);
    }

    var plan = try graph.GraphPlan.init(options.allocator, expected.page_count, expected.seed);
    defer plan.deinit(options.allocator);
    if (actual_code == expected_code and expected_code == 0) {
        try applyPostPublishBarbs(options.io, options.allocator, fixture_abs, &plan, expected.assignments, artifact_inventory.?);
    }
    const output_tree = try hashTree(options.io, options.allocator, fixture_abs, "results/boris-output");
    const output_snapshot = try writeOutputSnapshot(options.io, options.allocator, fixture_abs, "results/boris-output");
    const canonical_inventory_unchanged: ?bool = if (artifact_inventory) |inventory| blk: {
        const inventory_path = try std.fs.path.join(options.allocator, &.{
            fixture_abs,
            "results/boris-output/_boris/proof/artifacts.json",
        });
        defer options.allocator.free(inventory_path);
        const after_hash = try hashFileAbsolute(options.io, inventory_path);
        break :blk std.mem.eql(u8, &after_hash, &inventory.sha256);
    } else null;
    const passed = actual_code == expected_code and (canonical_inventory_unchanged orelse true);

    var fixture = try Io.Dir.openDirAbsolute(options.io, fixture_abs, .{});
    defer fixture.close(options.io);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(options.allocator);
    try output.appendSlice(options.allocator, "{\n  \"schemaVersion\":\"boris-testdata-run/3\",\n  \"expectedExitCode\":");
    try appendDecimal(&output, options.allocator, expected_code);
    try output.appendSlice(options.allocator, ",\n  \"actualExitCode\":");
    try appendDecimal(&output, options.allocator, actual_code);
    try output.appendSlice(options.allocator, ",\n  \"passed\":");
    try output.appendSlice(options.allocator, if (passed) "true" else "false");
    try output.appendSlice(options.allocator, ",\n  \"binarySha256\":");
    try manifest.appendJsonString(&output, options.allocator, &binary_hash);
    try output.appendSlice(options.allocator, ",\n  \"baselineOutputTreeSha256\":");
    try manifest.appendJsonString(&output, options.allocator, &baseline_tree.hash);
    try output.appendSlice(options.allocator, ",\n  \"baselineOutputFileCount\":");
    try appendDecimal(&output, options.allocator, baseline_tree.file_count);
    try output.appendSlice(options.allocator, ",\n  \"baselineArtifactInventory\":");
    if (artifact_inventory) |inventory| {
        try output.appendSlice(options.allocator, "{\"path\":\"results/boris-output/_boris/proof/artifacts.json\",\"sha256\":");
        try manifest.appendJsonString(&output, options.allocator, &inventory.sha256);
        try output.appendSlice(options.allocator, ",\"fileCount\":");
        try appendDecimal(&output, options.allocator, inventory.count);
        try output.append(options.allocator, '}');
    } else {
        try output.appendSlice(options.allocator, "null");
    }
    try output.appendSlice(options.allocator, ",\n  \"outputTreeSha256\":");
    try manifest.appendJsonString(&output, options.allocator, &output_tree.hash);
    try output.appendSlice(options.allocator, ",\n  \"outputFileCount\":");
    try appendDecimal(&output, options.allocator, output_tree.file_count);
    try output.appendSlice(options.allocator, ",\n  \"artifactInventorySha256\":");
    if (artifact_inventory) |inventory| {
        try manifest.appendJsonString(&output, options.allocator, &inventory.sha256);
    } else {
        try output.appendSlice(options.allocator, "null");
    }
    try output.appendSlice(options.allocator, ",\n  \"artifactInventoryFileCount\":");
    if (artifact_inventory) |inventory| {
        try appendDecimal(&output, options.allocator, inventory.count);
    } else {
        try output.appendSlice(options.allocator, "null");
    }
    try output.appendSlice(options.allocator, ",\n  \"outputSnapshotSha256\":");
    try manifest.appendJsonString(&output, options.allocator, &output_snapshot.sha256);
    try output.appendSlice(options.allocator, ",\n  \"outputSnapshotFileCount\":");
    try appendDecimal(&output, options.allocator, output_snapshot.count);
    try output.appendSlice(options.allocator, ",\n  \"artifactTargets\":[");
    if (artifact_inventory) |inventory| {
        try appendArtifactTargets(&output, options.allocator, expected.assignments, inventory);
    }
    try output.appendSlice(options.allocator, "]");
    try output.appendSlice(options.allocator, ",\n  \"appliedPostPublishMutations\":[");
    if (artifact_inventory != null) {
        try appendAppliedPostPublishMutations(&output, options.allocator, expected.assignments);
    }
    try output.appendSlice(options.allocator, "]");
    try output.appendSlice(options.allocator, ",\n  \"postPublishBarbsApplied\":");
    try appendDecimal(
        &output,
        options.allocator,
        if (artifact_inventory != null) countPostPublishBarbs(expected.assignments) else 0,
    );
    try output.appendSlice(options.allocator, ",\n  \"canonicalArtifactInventoryUnchanged\":");
    if (canonical_inventory_unchanged) |unchanged| {
        try output.appendSlice(options.allocator, if (unchanged) "true" else "false");
    } else {
        try output.appendSlice(options.allocator, "null");
    }
    try output.appendSlice(options.allocator, ",\n  \"poisonedOutputSnapshot\":{\"path\":\"results/output-snapshot.json\",\"sha256\":");
    try manifest.appendJsonString(&output, options.allocator, &output_snapshot.sha256);
    try output.appendSlice(options.allocator, ",\"fileCount\":");
    try appendDecimal(&output, options.allocator, output_snapshot.count);
    try output.append(options.allocator, '}');
    try output.appendSlice(options.allocator, ",\n  \"stdout\":");
    try manifest.appendJsonString(&output, options.allocator, result.stdout);
    try output.appendSlice(options.allocator, ",\n  \"stderr\":");
    try manifest.appendJsonString(&output, options.allocator, result.stderr);
    try output.appendSlice(options.allocator, "\n}\n");
    try fixture.writeFile(options.io, .{ .sub_path = "results/run.json", .data = output.items });

    if (!passed) return error.BorisExpectationMismatch;
}

pub fn republishCleanFixture(options: RunOptions) !void {
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

    const clean_abs = try std.fs.path.join(options.allocator, &.{ fixture_abs, "results/republish-clean-output" });
    defer options.allocator.free(clean_abs);
    if (pathExists(options.io, clean_abs)) try deletePath(options.io, clean_abs);

    const input_arg = try std.fmt.allocPrint(options.allocator, "{s}/content", .{base});
    defer options.allocator.free(input_arg);
    const html_arg = try std.fmt.allocPrint(options.allocator, "{s}/results/republish-clean-output", .{base});
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
    const output_tree = try hashTree(options.io, options.allocator, fixture_abs, "results/republish-clean-output");
    const passed = actual_code == expected.exit_code;

    var fixture = try Io.Dir.openDirAbsolute(options.io, fixture_abs, .{});
    defer fixture.close(options.io);
    var output = std.ArrayList(u8).empty;
    defer output.deinit(options.allocator);
    try output.appendSlice(options.allocator, "{\n  \"schemaVersion\":\"boris-testdata-republish-clean/1\",\n  \"expectedExitCode\":");
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
    try fixture.writeFile(options.io, .{ .sub_path = "results/republish-clean.json", .data = output.items });

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

fn writeOutputSnapshot(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    output_relative: []const u8,
) !manifest.InventorySummary {
    var fixture = try Io.Dir.openDirAbsolute(io, fixture_abs, .{ .iterate = true });
    defer fixture.close(io);
    var results = try fixture.openDir(io, "results", .{});
    defer results.close(io);

    var snapshot = try manifest.Inventory.openNamed(io, results, "output-snapshot.jsonl");
    var snapshot_open = true;
    defer {
        if (snapshot_open) _ = snapshot.close();
    }

    var output = fixture.openDir(io, output_relative, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => {
            const summary = snapshot.close();
            snapshot_open = false;
            try manifest.writeOutputSnapshotSummary(io, results, allocator, output_relative, summary);
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
        try snapshot.add(allocator, path, "tree-entry", bytes, null, null, null);
    }
    const summary = snapshot.close();
    snapshot_open = false;
    try manifest.writeOutputSnapshotSummary(io, results, allocator, output_relative, summary);
    return summary;
}

const ArtifactRecord = struct {
    path: []u8 = &.{},
    kind: []u8 = &.{},
    bytes: u64 = 0,
    sha256: manifest.HashText = undefined,
    committed: bool = false,

    fn deinit(self: *ArtifactRecord, allocator: std.mem.Allocator) void {
        if (self.path.len > 0) allocator.free(self.path);
        if (self.kind.len > 0) allocator.free(self.kind);
        self.* = undefined;
    }
};

const ArtifactTarget = struct {
    index: usize,
    path: []u8,
    kind: []u8,
    bytes: u64,
    sha256: manifest.HashText,

    fn deinit(self: *ArtifactTarget, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.kind);
        self.* = undefined;
    }
};

const ArtifactInventory = struct {
    sha256: manifest.HashText,
    count: usize,
    targets: []ArtifactTarget,

    fn deinit(self: *ArtifactInventory, allocator: std.mem.Allocator) void {
        for (self.targets) |*target| target.deinit(allocator);
        allocator.free(self.targets);
        self.* = undefined;
    }

    fn targetFor(self: *const ArtifactInventory, index: usize) ?*const ArtifactTarget {
        for (self.targets) |*target| {
            if (target.index == index) return target;
        }
        return null;
    }
};

fn readArtifactInventory(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    assignments: []const barbs.Assignment,
) !ArtifactInventory {
    const inventory_path = try std.fs.path.join(allocator, &.{ fixture_abs, "results/boris-output/_boris/proof/artifacts.json" });
    defer allocator.free(inventory_path);

    const inventory_hash = try hashFileAbsolute(io, inventory_path);
    const count = try scanArtifactInventory(io, allocator, inventory_path, &.{}, null);
    if (count == 0) return error.InvalidArtifactInventory;

    var wanted: std.ArrayList(usize) = .empty;
    defer wanted.deinit(allocator);
    for (assignments) |assignment| {
        if (assignment.kind == .artifact_missing or assignment.kind == .artifact_digest_mismatch) {
            try wanted.append(allocator, assignment.target % count);
        }
    }

    var targets: std.ArrayList(ArtifactTarget) = .empty;
    errdefer {
        for (targets.items) |*target| target.deinit(allocator);
        targets.deinit(allocator);
    }
    if (wanted.items.len > 0) {
        const selected_count = try scanArtifactInventory(io, allocator, inventory_path, wanted.items, &targets);
        if (selected_count != count) return error.InvalidArtifactInventory;
        for (wanted.items) |index| {
            if (!hasTarget(targets.items, index)) return error.InvalidArtifactInventory;
        }
        try preflightArtifactTargets(io, allocator, fixture_abs, targets.items);
    }
    return .{
        .sha256 = inventory_hash,
        .count = count,
        .targets = try targets.toOwnedSlice(allocator),
    };
}

/// Validate every selected artifact against the clean publication before any
/// post-publication mutation can change the bytes. Later mutations deliberately
/// use these retained baseline facts without revalidating the poisoned tree.
fn preflightArtifactTargets(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    targets: []const ArtifactTarget,
) !void {
    for (targets) |target| {
        const bytes = try readOutputPath(io, allocator, fixture_abs, target.path);
        defer allocator.free(bytes);
        if (@as(u64, bytes.len) != target.bytes) return error.InvalidArtifactInventory;
        const actual = manifest.sha256Hex(bytes);
        if (!std.mem.eql(u8, &actual, &target.sha256)) return error.InvalidArtifactInventory;
    }
}

fn scanArtifactInventory(
    io: Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    wanted: []const usize,
    targets: ?*std.ArrayList(ArtifactTarget),
) !usize {
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var input_buffer: [64 * 1024]u8 = undefined;
    var file_reader = file.readerStreaming(io, &input_buffer);
    var reader = std.json.Reader.init(allocator, &file_reader.interface);
    defer reader.deinit();

    const root = try reader.next();
    switch (root) {
        .object_begin => {},
        else => return error.InvalidArtifactInventory,
    }

    var have_artifacts = false;
    var committed_count: usize = 0;
    while (true) {
        const key_token = try reader.nextAllocMax(allocator, .alloc_if_needed, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(allocator, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidArtifactInventory;
        if (std.mem.eql(u8, key, "format")) {
            const value = try readJsonString(allocator, &reader);
            defer allocator.free(value);
            if (!std.mem.eql(u8, value, "boris-publication-artifacts")) return error.InvalidArtifactInventory;
        } else if (std.mem.eql(u8, key, "schema_version")) {
            if (try readJsonInteger(allocator, &reader) != 1) return error.InvalidArtifactInventory;
        } else if (std.mem.eql(u8, key, "target")) {
            const value = try readJsonString(allocator, &reader);
            defer allocator.free(value);
            if (value.len == 0) return error.InvalidArtifactInventory;
        } else if (std.mem.eql(u8, key, "artifacts")) {
            if (have_artifacts) return error.InvalidArtifactInventory;
            have_artifacts = true;
            const array_begin = try reader.next();
            switch (array_begin) {
                .array_begin => {},
                else => return error.InvalidArtifactInventory,
            }
            while (true) {
                const item = try reader.next();
                switch (item) {
                    .array_end => break,
                    .object_begin => {
                        var record = try readArtifactRecord(allocator, &reader);
                        errdefer record.deinit(allocator);
                        if (record.committed) {
                            const index = committed_count;
                            committed_count = std.math.add(usize, committed_count, 1) catch return error.InvalidArtifactInventory;
                            if (targets) |target_list| {
                                if (containsIndex(wanted, index) and !hasTarget(target_list.items, index)) {
                                    const target = ArtifactTarget{
                                        .index = index,
                                        .path = record.path,
                                        .kind = record.kind,
                                        .bytes = record.bytes,
                                        .sha256 = record.sha256,
                                    };
                                    record.path = &.{};
                                    record.kind = &.{};
                                    try target_list.append(allocator, target);
                                }
                            }
                        }
                        record.deinit(allocator);
                    },
                    else => return error.InvalidArtifactInventory,
                }
            }
        } else {
            return error.InvalidArtifactInventory;
        }
    }
    if (!have_artifacts) return error.InvalidArtifactInventory;
    const end = try reader.next();
    if (end != .end_of_document) return error.InvalidArtifactInventory;
    return committed_count;
}

fn readArtifactRecord(allocator: std.mem.Allocator, reader: *std.json.Reader) !ArtifactRecord {
    var record = ArtifactRecord{};
    errdefer record.deinit(allocator);
    var have_path = false;
    var have_kind = false;
    var have_bytes = false;
    var have_sha256 = false;
    var have_status = false;
    var have_required = false;
    var have_producer = false;
    while (true) {
        const key_token = try reader.nextAllocMax(allocator, .alloc_if_needed, 4096);
        switch (key_token) {
            .object_end => break,
            else => {},
        }
        defer freeJsonToken(allocator, key_token);
        const key = jsonTokenText(key_token) orelse return error.InvalidArtifactInventory;
        if (std.mem.eql(u8, key, "path")) {
            if (have_path) return error.InvalidArtifactInventory;
            record.path = try readJsonString(allocator, reader);
            have_path = true;
        } else if (std.mem.eql(u8, key, "kind")) {
            if (have_kind) return error.InvalidArtifactInventory;
            record.kind = try readJsonString(allocator, reader);
            have_kind = true;
        } else if (std.mem.eql(u8, key, "bytes")) {
            if (have_bytes) return error.InvalidArtifactInventory;
            record.bytes = try readJsonInteger(allocator, reader);
            have_bytes = true;
        } else if (std.mem.eql(u8, key, "sha256")) {
            if (have_sha256) return error.InvalidArtifactInventory;
            const digest = try readJsonString(allocator, reader);
            defer allocator.free(digest);
            if (!validDigest(digest)) return error.InvalidArtifactInventory;
            @memcpy(record.sha256[0..], digest);
            have_sha256 = true;
        } else if (std.mem.eql(u8, key, "status")) {
            if (have_status) return error.InvalidArtifactInventory;
            const status = try readJsonString(allocator, reader);
            defer allocator.free(status);
            if (std.mem.eql(u8, status, "committed")) {
                record.committed = true;
            } else if (!std.mem.eql(u8, status, "omitted-by-plan") and !std.mem.eql(u8, status, "not-applicable")) {
                return error.InvalidArtifactInventory;
            }
            have_status = true;
        } else if (std.mem.eql(u8, key, "required")) {
            if (have_required) return error.InvalidArtifactInventory;
            _ = try readJsonBool(reader);
            have_required = true;
        } else if (std.mem.eql(u8, key, "producer")) {
            if (have_producer) return error.InvalidArtifactInventory;
            const producer = try readJsonString(allocator, reader);
            defer allocator.free(producer);
            if (producer.len == 0) return error.InvalidArtifactInventory;
            have_producer = true;
        } else if (std.mem.eql(u8, key, "format_version")) {
            const token = try reader.nextAllocMax(allocator, .alloc_if_needed, 4096);
            defer freeJsonToken(allocator, token);
            switch (token) {
                .null => {},
                .string, .allocated_string => {},
                else => return error.InvalidArtifactInventory,
            }
        } else {
            return error.InvalidArtifactInventory;
        }
    }
    if (!have_path or !safeArtifactPath(record.path) or !have_kind or !isArtifactKind(record.kind) or
        !have_bytes or !have_sha256 or !have_status or !have_required or !have_producer)
    {
        return error.InvalidArtifactInventory;
    }
    return record;
}

fn readJsonString(allocator: std.mem.Allocator, reader: *std.json.Reader) ![]u8 {
    const token = try reader.nextAllocMax(allocator, .alloc_always, 4 * 1024 * 1024);
    switch (token) {
        .allocated_string => |value| return value,
        .string => |value| return allocator.dupe(u8, value),
        else => {
            freeJsonToken(allocator, token);
            return error.InvalidArtifactInventory;
        },
    }
}

fn readJsonInteger(allocator: std.mem.Allocator, reader: *std.json.Reader) !u64 {
    const token = try reader.nextAllocMax(allocator, .alloc_if_needed, 64);
    defer freeJsonToken(allocator, token);
    const value = jsonTokenText(token) orelse return error.InvalidArtifactInventory;
    return std.fmt.parseInt(u64, value, 10) catch return error.InvalidArtifactInventory;
}

fn readJsonBool(reader: *std.json.Reader) !bool {
    return switch (try reader.next()) {
        .true => true,
        .false => false,
        else => error.InvalidArtifactInventory,
    };
}

fn jsonTokenText(token: std.json.Token) ?[]const u8 {
    return switch (token) {
        .string => |value| value,
        .allocated_string => |value| value,
        .number => |value| value,
        .allocated_number => |value| value,
        else => null,
    };
}

fn freeJsonToken(allocator: std.mem.Allocator, token: std.json.Token) void {
    switch (token) {
        .allocated_string => |value| allocator.free(value),
        .allocated_number => |value| allocator.free(value),
        else => {},
    }
}

fn validDigest(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f'))) return false;
    }
    return true;
}

fn safeArtifactPath(path: []const u8) bool {
    if (path.len == 0 or path[0] == '/' or std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn isArtifactKind(kind: []const u8) bool {
    return std.mem.eql(u8, kind, "html-page") or
        std.mem.eql(u8, kind, "theme-asset") or
        std.mem.eql(u8, kind, "content-asset") or
        std.mem.eql(u8, kind, "rendered-search") or
        std.mem.eql(u8, kind, "sitemap") or
        std.mem.eql(u8, kind, "rss") or
        std.mem.eql(u8, kind, "llms");
}

fn containsIndex(values: []const usize, needle: usize) bool {
    for (values) |value| if (value == needle) return true;
    return false;
}

fn hasTarget(values: []const ArtifactTarget, needle: usize) bool {
    for (values) |value| if (value.index == needle) return true;
    return false;
}

fn hashFileAbsolute(io: Io, path: []const u8) !manifest.HashText {
    var file = try Io.Dir.openFileAbsolute(io, path, .{});
    defer file.close(io);
    var reader = file.readerStreaming(io, &.{});
    var input_buffer: [64 * 1024]u8 = undefined;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    while (true) {
        const count = try reader.interface.readSliceShort(&input_buffer);
        if (count == 0) break;
        hasher.update(input_buffer[0..count]);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return manifest.digestToHex(digest);
}

fn appendArtifactTargets(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    assignments: []const barbs.Assignment,
    inventory: ArtifactInventory,
) !void {
    var first = true;
    for (assignments) |assignment| {
        if (assignment.kind != .artifact_missing and assignment.kind != .artifact_digest_mismatch) continue;
        const index = assignment.target % inventory.count;
        const target = inventory.targetFor(index) orelse return error.InvalidArtifactInventory;
        if (!first) try output.append(allocator, ',');
        first = false;
        try output.appendSlice(allocator, "{\"barb\":");
        try manifest.appendJsonString(output, allocator, barbs.name(assignment.kind));
        try output.appendSlice(allocator, ",\"baselineIndex\":");
        try appendDecimal(output, allocator, index);
        try output.appendSlice(allocator, ",\"path\":");
        try manifest.appendJsonString(output, allocator, target.path);
        try output.appendSlice(allocator, ",\"kind\":");
        try manifest.appendJsonString(output, allocator, target.kind);
        try output.appendSlice(allocator, ",\"bytes\":");
        try appendDecimal(output, allocator, target.bytes);
        try output.appendSlice(allocator, ",\"sha256\":");
        try manifest.appendJsonString(output, allocator, &target.sha256);
        try output.append(allocator, '}');
    }
}

fn appendAppliedPostPublishMutations(
    output: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    assignments: []const barbs.Assignment,
) !void {
    var first = true;
    for (assignments) |assignment| {
        if (!barbs.isPostPublish(assignment.kind)) continue;
        if (!first) try output.append(allocator, ',');
        first = false;
        try output.appendSlice(allocator, "{\"name\":");
        try manifest.appendJsonString(output, allocator, barbs.name(assignment.kind));
        try output.appendSlice(allocator, ",\"targetIndex\":");
        try appendDecimal(output, allocator, assignment.target);
        try output.appendSlice(allocator, ",\"secondaryIndex\":");
        if (assignment.secondary) |secondary| {
            try appendDecimal(output, allocator, secondary);
        } else {
            try output.appendSlice(allocator, "null");
        }
        try output.append(allocator, '}');
    }
}

fn applyPostPublishBarbs(
    io: Io,
    allocator: std.mem.Allocator,
    fixture_abs: []const u8,
    plan: *const graph.GraphPlan,
    assignments: []const barbs.Assignment,
    artifact_inventory: ArtifactInventory,
) !void {
    // Apply byte-preserving and byte-changing mutations first. Artifact
    // deletion is intentionally last so a missing-artifact barb cannot remove
    // the surface needed by another selected mutation. All artifact targets
    // were preflighted from the clean publication before this function ran.
    for (assignments) |assignment| {
        if (!barbs.isPostPublish(assignment.kind) or assignment.kind == .artifact_missing) continue;
        if (assignment.target >= plan.pages.len) return error.InvalidFixture;
        switch (assignment.kind) {
            .html_missing_local_route,
            .html_missing_fragment,
            .html_duplicate_id,
            .html_unclosed_structure,
            => try mutateHtmlOutput(io, allocator, fixture_abs, plan.pages[assignment.target], assignment.kind),
            .artifact_digest_mismatch => {
                const target = artifactTargetForAssignment(artifact_inventory, assignment) orelse return error.InvalidArtifactInventory;
                try mutateDigestOutput(io, allocator, fixture_abs, target.path);
            },
            .search_stale_title => try mutateSearchTitle(io, allocator, fixture_abs),
            .deployment_owned_extra => try writeDeploymentOwnedExtra(io, fixture_abs),
            else => unreachable,
        }
    }

    // A missing artifact is a final-state mutation. If another mutation shares
    // its path, both mutations are still recorded and the deletion wins in the
    // poisoned tree without invalidating clean-baseline bookkeeping.
    for (assignments) |assignment| {
        if (assignment.kind != .artifact_missing) continue;
        if (assignment.target >= plan.pages.len) return error.InvalidFixture;
        const target = artifactTargetForAssignment(artifact_inventory, assignment) orelse return error.InvalidArtifactInventory;
        try deleteOutputPath(io, allocator, fixture_abs, target.path);
    }
}

fn artifactTargetForAssignment(inventory: ArtifactInventory, assignment: barbs.Assignment) ?*const ArtifactTarget {
    if (inventory.count == 0) return null;
    return inventory.targetFor(assignment.target % inventory.count);
}

fn outputPagePath(allocator: std.mem.Allocator, page: graph.PagePlan) ![]u8 {
    var id_buffer: [192]u8 = undefined;
    return std.fmt.allocPrint(allocator, "{s}.html", .{try graph.GraphPlan.id(page, &id_buffer)});
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

test "asset-excluded profiles do not emit dangling generated image references" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const output_path = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}/preserved-edge", .{tmp.sub_path});
    defer a.free(output_path);
    var generated = try generate(.{
        .io = io,
        .allocator = a,
        .output_path = output_path,
        .pages = 24,
        .seed = 20260801,
        .profile_selector = "preserved-edge-v1",
    });
    defer {
        a.free(generated.assignments);
        generated.profile.deinit(a);
    }

    const index_path = try std.fmt.allocPrint(a, "{s}/content/index.md", .{output_path});
    defer a.free(index_path);
    const index_bytes = try readFilePath(io, a, index_path, 256 * 1024);
    defer a.free(index_bytes);
    try std.testing.expect(std.mem.indexOf(u8, index_bytes, "![Generated diagram]") == null);

    const assets_path = try std.fmt.allocPrint(a, "{s}/content/index.assets", .{output_path});
    defer a.free(assets_path);
    try std.testing.expect(!pathExists(io, assets_path));

    var plan = try graph.GraphPlan.init(a, generated.page_count, 20260801);
    defer plan.deinit(a);
    const assignment = generated.assignments[0];
    var source_buffer: [224]u8 = undefined;
    const source_path = try graph.GraphPlan.sourcePath(plan.pages[assignment.target], &source_buffer);
    const edge_path = try std.fmt.allocPrint(a, "{s}/content/{s}", .{ output_path, source_path });
    defer a.free(edge_path);
    const edge_bytes = try readFilePath(io, a, edge_path, 256 * 1024);
    defer a.free(edge_bytes);
    try std.testing.expect(std.mem.indexOf(u8, edge_bytes, "[escape](../../../../outside.md)") != null);
}

test "artifact mutations use clean baseline targets across overlapping surfaces" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_arena = std.heap.ArenaAllocator.init(a);
    defer path_arena.deinit();
    const pa = path_arena.allocator();

    const fixture_rel = try std.fmt.allocPrint(pa, ".zig-cache/tmp/{s}/artifact-overlap", .{tmp.sub_path});
    const output_rel = try std.fmt.allocPrint(pa, "{s}/results/boris-output", .{fixture_rel});
    const proof_rel = try std.fmt.allocPrint(pa, "{s}/_boris/proof", .{output_rel});
    const cwd = Io.Dir.cwd();
    try cwd.createDirPath(io, proof_rel);

    const baseline = "<html><body><main>baseline</main></body></html>\n";
    const output_file_rel = try std.fmt.allocPrint(pa, "{s}/index.html", .{output_rel});
    try cwd.writeFile(io, .{ .sub_path = output_file_rel, .data = baseline });
    const digest = manifest.sha256Hex(baseline);
    const inventory = try std.fmt.allocPrint(
        pa,
        "{{\n  \"format\":\"boris-publication-artifacts\",\n  \"schema_version\":1,\n  \"target\":\"default\",\n  \"artifacts\":[{{\"path\":\"index.html\",\"kind\":\"html-page\",\"producer\":\"html-render\",\"required\":true,\"status\":\"committed\",\"bytes\":{d},\"sha256\":\"{s}\",\"format_version\":null}}]\n}}\n",
        .{ baseline.len, &digest },
    );
    const inventory_rel = try std.fmt.allocPrint(pa, "{s}/artifacts.json", .{proof_rel});
    try cwd.writeFile(io, .{ .sub_path = inventory_rel, .data = inventory });

    const cwd_path = try std.process.currentPathAlloc(io, a);
    defer a.free(cwd_path);
    const fixture_abs = try std.fs.path.resolve(a, &.{ cwd_path, fixture_rel });
    defer a.free(fixture_abs);
    const overlap_assignments = [_]barbs.Assignment{
        .{ .kind = .html_duplicate_id, .target = 0 },
        .{ .kind = .artifact_digest_mismatch, .target = 0 },
    };
    var selected = try readArtifactInventory(io, a, fixture_abs, &overlap_assignments);
    defer selected.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), selected.targets.len);
    try std.testing.expectEqualStrings("index.html", selected.targets[0].path);
    try std.testing.expectEqual(@as(u64, baseline.len), selected.targets[0].bytes);
    try std.testing.expectEqual(digest, selected.targets[0].sha256);

    var plan = try graph.GraphPlan.init(a, 1, 20260801);
    defer plan.deinit(a);
    try applyPostPublishBarbs(io, a, fixture_abs, &plan, &overlap_assignments, selected);
    const mutated_path = try std.fs.path.join(a, &.{ fixture_abs, "results/boris-output/index.html" });
    defer a.free(mutated_path);
    const mutated = try readFileAbsolute(io, a, mutated_path, 256 * 1024);
    defer a.free(mutated);
    try std.testing.expect(std.mem.indexOf(u8, mutated, "boris-testdata-duplicate-id") != null);
    const mutated_digest = manifest.sha256Hex(mutated);
    try std.testing.expect(!std.mem.eql(u8, &mutated_digest, &digest));
    const inventory_path = try std.fs.path.join(a, &.{ fixture_abs, "results/boris-output/_boris/proof/artifacts.json" });
    defer a.free(inventory_path);
    const after_overlap_hash = try hashFileAbsolute(io, inventory_path);
    try std.testing.expectEqual(selected.sha256, after_overlap_hash);

    try cwd.writeFile(io, .{ .sub_path = output_file_rel, .data = baseline });
    const missing_assignments = [_]barbs.Assignment{.{ .kind = .artifact_missing, .target = 0 }};
    try applyPostPublishBarbs(io, a, fixture_abs, &plan, &missing_assignments, selected);
    try std.testing.expect(!pathExists(io, mutated_path));
    const after_missing_hash = try hashFileAbsolute(io, inventory_path);
    try std.testing.expectEqual(selected.sha256, after_missing_hash);
}
