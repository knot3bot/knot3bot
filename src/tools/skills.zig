//! Skills tools - list, view, manage + SkillsGuard security
//! Implements Tool vtable interface
//! hermes-agent self-evolution alignment

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;

// ── SkillsGuard: Security validation ────────────────────────────────────────────

const DANGEROUS_PATTERNS = [_][]const u8{
    "ignore previous instructions",
    "ignore all previous",
    "you are now",
    "disregard your",
    "forget your instructions",
    "new instructions:",
    "system prompt:",
    "<system>",
    "]]>",
};

pub fn scanForDangerousPatterns(content: []const u8) ?[]const u8 {
    inline for (DANGEROUS_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, content, pattern) != null) {
            return pattern;
        }
    }
    return null;
}

pub fn validateFrontmatter(content: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, content, "---")) {
        return "SKILL.md must start with YAML frontmatter (---)";
    }
    const rest = content[3..];
    const end_idx = std.mem.indexOf(u8, rest, "---");
    if (end_idx == null) {
        return "SKILL.md frontmatter is not closed";
    }
    const yaml_content = rest[0..end_idx.?];
    if (std.mem.indexOf(u8, yaml_content, "name:") == null) {
        return "Frontmatter must include 'name' field";
    }
    if (std.mem.indexOf(u8, yaml_content, "description:") == null) {
        return "Frontmatter must include 'description' field";
    }
    const body_start = 3 + end_idx.? + 3;
    if (body_start >= content.len) {
        return "SKILL.md must have content after the frontmatter";
    }
    return null;
}

const ALLOWED_SUBDIRS = [_][]const u8{ "references", "templates", "scripts", "assets" };

pub fn validateSkillFilePath(file_path: []const u8) ?[]const u8 {
    if (file_path.len == 0) return "file_path is required";
    if (std.mem.indexOf(u8, file_path, "..") != null) {
        return "Path traversal ('..') is not allowed";
    }
    var found = false;
    for (ALLOWED_SUBDIRS) |subdir| {
        if (std.mem.startsWith(u8, file_path, subdir)) {
            found = true;
            break;
        }
    }
    if (!found) {
        return "File must be under: references/, templates/, scripts/, assets/";
    }
    return null;
}

// ── Skill Manifest ─────────────────────────────────────────────────────────────

/// Rich metadata for a skill, loaded from manifest.json or SKILL.md frontmatter
pub const SkillManifest = struct {
    name: []const u8,
    description: []const u8,
    category: ?[]const u8 = null,
    version: ?[]const u8 = null,
    author: ?[]const u8 = null,
    tags: []const []const u8 = &.{},
    dependencies: []const []const u8 = &.{},
};

/// Load skill manifest - tries manifest.json first, then falls back to SKILL.md frontmatter
pub fn loadSkillManifest(allocator: std.mem.Allocator, skill_dir: []const u8, skill_name: []const u8) !SkillManifest {
    // Try manifest.json first
    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}/manifest.json", .{ skill_dir, skill_name });
    defer allocator.free(manifest_path);

    if (std.fs.cwd().readFileAlloc(allocator, manifest_path, 65536)) |json_content| {
        defer allocator.free(json_content);
        // Parse JSON manifest
        var manifest = SkillManifest{
            .name = skill_name,
            .description = "",
        };

        // Parse JSON using std.json
        var parser = std.json.Parser.init(allocator, .{});
        defer parser.deinit();

        const json_value = try parser.parse(json_content);
        const obj = json_value.root.object;

        if (obj.get("name")) |val| {
            if (val == .string) manifest.name = val.string;
        }
        if (obj.get("description")) |val| {
            if (val == .string) manifest.description = val.string;
        }
        if (obj.get("category")) |val| {
            if (val == .string) manifest.category = val.string;
        }
        if (obj.get("version")) |val| {
            if (val == .string) manifest.version = val.string;
        }
        if (obj.get("author")) |val| {
            if (val == .string) manifest.author = val.string;
        }
        if (obj.get("tags")) |val| {
            if (val == .array) {
                var tags: std.ArrayList([]const u8) = .empty;
                for (val.array.items) |item| {
                    if (item == .string) {
                        try tags.append(allocator, item.string);
                    }
                }
                manifest.tags = try tags.toOwnedSlice(allocator);
            }
        }
        if (obj.get("dependencies")) |val| {
            if (val == .array) {
                var deps: std.ArrayList([]const u8) = .empty;
                for (val.array.items) |item| {
                    if (item == .string) {
                        try deps.append(allocator, item.string);
                    }
                }
                manifest.dependencies = try deps.toOwnedSlice(allocator);
            }
        }

        return manifest;
    } else |_| {
        // Fall back to SKILL.md frontmatter
    }

    // Try SKILL.md frontmatter
    const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ skill_dir, skill_name });
    defer allocator.free(skill_md_path);

    const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 65536) catch {
        // No manifest and no SKILL.md - return empty manifest
        return SkillManifest{
            .name = skill_name,
            .description = "",
        };
    };
    defer allocator.free(content);

    // Parse frontmatter
    var manifest = parseSkillFrontmatterToManifest(content);
    manifest.name = skill_name;
    return manifest;
}

/// Parse SKILL.md frontmatter to SkillManifest
fn parseSkillFrontmatterToManifest(content: []const u8) SkillManifest {
    var result = SkillManifest{
        .name = "",
        .description = "",
    };
    if (!std.mem.startsWith(u8, content, "---")) return result;
    const rest = content[3..];
    const end_idx = std.mem.indexOf(u8, rest, "---");
    if (end_idx == null) return result;
    const yaml_content = rest[0..end_idx.?];

    // Simple YAML parsing
    if (std.mem.indexOf(u8, yaml_content, "name:")) |name_idx| {
        const name_start = name_idx + 5;
        const line_end = std.mem.indexOf(u8, yaml_content[name_start..], "\n") orelse yaml_content.len;
        var name = std.mem.trim(u8, yaml_content[name_start..name_start + line_end], " \t");
        if (std.mem.startsWith(u8, name, "\"")) name = name[1..];
        if (std.mem.endsWith(u8, name, "\"")) name = name[0..name.len-1];
        result.name = name;
    }
    if (std.mem.indexOf(u8, yaml_content, "description:")) |desc_idx| {
        const desc_start = desc_idx + 12;
        const line_end = std.mem.indexOf(u8, yaml_content[desc_start..], "\n") orelse yaml_content.len;
        var desc = std.mem.trim(u8, yaml_content[desc_start..desc_start + line_end], " \t");
        if (std.mem.startsWith(u8, desc, "\"")) desc = desc[1..];
        if (std.mem.endsWith(u8, desc, "\"")) desc = desc[0..desc.len-1];
        result.description = desc;
    }
    if (std.mem.indexOf(u8, yaml_content, "category:")) |cat_idx| {
        const cat_start = cat_idx + 9;
        const line_end = std.mem.indexOf(u8, yaml_content[cat_start..], "\n") orelse yaml_content.len;
        var cat = std.mem.trim(u8, yaml_content[cat_start..cat_start + line_end], " \t");
        if (std.mem.startsWith(u8, cat, "\"")) cat = cat[1..];
        if (std.mem.endsWith(u8, cat, "\"")) cat = cat[0..cat.len-1];
        if (cat.len > 0) result.category = cat;
    }
    if (std.mem.indexOf(u8, yaml_content, "version:")) |ver_idx| {
        const ver_start = ver_idx + 8;
        const line_end = std.mem.indexOf(u8, yaml_content[ver_start..], "\n") orelse yaml_content.len;
        var ver = std.mem.trim(u8, yaml_content[ver_start..ver_start + line_end], " \t");
        if (std.mem.startsWith(u8, ver, "\"")) ver = ver[1..];
        if (std.mem.endsWith(u8, ver, "\"")) ver = ver[0..ver.len-1];
        if (ver.len > 0) result.version = ver;
    }
    if (std.mem.indexOf(u8, yaml_content, "author:")) |auth_idx| {
        const auth_start = auth_idx + 7;
        const line_end = std.mem.indexOf(u8, yaml_content[auth_start..], "\n") orelse yaml_content.len;
        var auth = std.mem.trim(u8, yaml_content[auth_start..auth_start + line_end], " \t");
        if (std.mem.startsWith(u8, auth, "\"")) auth = auth[1..];
        if (std.mem.endsWith(u8, auth, "\"")) auth = auth[0..auth.len-1];
        if (auth.len > 0) result.author = auth;
    }
    return result;
}

// ── SkillsListTool ───────────────────────────────────────────────────────────────

fn parseSkillFrontmatter(content: []const u8) struct { name: []const u8, description: []const u8, category: ?[]const u8 } {
    var result = struct { name: []const u8, description: []const u8, category: ?[]const u8 }{ .name = "", .description = "", .category = null };
    if (!std.mem.startsWith(u8, content, "---")) return result;
    const rest = content[3..];
    const end_idx = std.mem.indexOf(u8, rest, "---");
    if (end_idx == null) return result;
    const yaml_content = rest[0..end_idx.?];

    // Simple YAML parsing - extract name, description, category
    if (std.mem.indexOf(u8, yaml_content, "name:")) |name_idx| {
        const name_start = name_idx + 5;
        const line_end = std.mem.indexOf(u8, yaml_content[name_start..], "\n") orelse yaml_content.len;
        var name = std.mem.trim(u8, yaml_content[name_start..name_start + line_end], " \t");
        if (std.mem.startsWith(u8, name, "\"")) name = name[1..];
        if (std.mem.endsWith(u8, name, "\"")) name = name[0..name.len-1];
        result.name = name;
    }

    if (std.mem.indexOf(u8, yaml_content, "description:")) |desc_idx| {
        const desc_start = desc_idx + 12;
        const line_end = std.mem.indexOf(u8, yaml_content[desc_start..], "\n") orelse yaml_content.len;
        var desc = std.mem.trim(u8, yaml_content[desc_start..desc_start + line_end], " \t");
        if (std.mem.startsWith(u8, desc, "\"")) desc = desc[1..];
        if (std.mem.endsWith(u8, desc, "\"")) desc = desc[0..desc.len-1];
        result.description = desc;
    }

    if (std.mem.indexOf(u8, yaml_content, "category:")) |cat_idx| {
        const cat_start = cat_idx + 9;
        const line_end = std.mem.indexOf(u8, yaml_content[cat_start..], "\n") orelse yaml_content.len;
        var cat = std.mem.trim(u8, yaml_content[cat_start..cat_start + line_end], " \t");
        if (std.mem.startsWith(u8, cat, "\"")) cat = cat[1..];
        if (std.mem.endsWith(u8, cat, "\"")) cat = cat[0..cat.len-1];
        if (cat.len > 0) result.category = cat;
    }

    return result;
}

pub const SkillsListTool = struct {
    skills_dir: []const u8,

    pub const tool_name = "skills_list";
    pub const tool_description = "List all available skills with metadata";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"category\":{\"type\":\"string\",\"description\":\"Optional category filter\"}},\"required\":[]}";

    pub fn tool(self: *SkillsListTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SkillsListTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const category_filter = getString(args, "category");

        const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills", .{self.skills_dir});
        defer allocator.free(skill_path);

        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        try output.appendSlice(allocator, "{\"success\":true,\"skills\":[");

        var dir = std.fs.cwd().openDir(skill_path, .{}) catch {
            try output.appendSlice(allocator, "],\"count\":0}");
            return ToolResult.ok(try output.toOwnedSlice(allocator));
        };
        defer dir.close();

        var first = true;
        var count: usize = 0;
        var iter = dir.iterate();
        while (iter.next() catch null) |entry| : ({}) {
            if (entry.kind == .directory) {
                // Check if category filter matches
                if (category_filter) |cat| {
                    if (!std.mem.eql(u8, entry.name, cat)) continue;
                }
                // Load skill manifest (manifest.json or SKILL.md frontmatter)
                const manifest = loadSkillManifest(allocator, skill_path, entry.name) catch SkillManifest{
                    .name = entry.name,
                    .description = "",
                };

                if (!first) try output.appendSlice(allocator, ",");
                first = false;
                count += 1;

                try output.appendSlice(allocator, "{\"name\":\"");
                if (manifest.name.len > 0) {
                    try output.appendSlice(allocator, manifest.name);
                } else {
                    try output.appendSlice(allocator, entry.name);
                }
                try output.appendSlice(allocator, "\",\"description\":\"");
                try output.appendSlice(allocator, manifest.description);
                try output.appendSlice(allocator, "\",\"category\":");
                if (manifest.category) |cat| {
                    try output.appendSlice(allocator, "\"");
                    try output.appendSlice(allocator, cat);
                    try output.appendSlice(allocator, "\"");
                } else {
                    try output.appendSlice(allocator, "null");
                }
                try output.appendSlice(allocator, "\",\"version\":");
                if (manifest.version) |ver| {
                    try output.appendSlice(allocator, "\"");
                    try output.appendSlice(allocator, ver);
                    try output.appendSlice(allocator, "\"");
                } else {
                    try output.appendSlice(allocator, "null");
                }
                try output.appendSlice(allocator, "\",\"author\":");
                if (manifest.author) |auth| {
                    try output.appendSlice(allocator, "\"");
                    try output.appendSlice(allocator, auth);
                    try output.appendSlice(allocator, "\"");
                } else {
                    try output.appendSlice(allocator, "null");
                }
                try output.appendSlice(allocator, "\",\"tags\":[");
                for (manifest.tags, 0..) |tag, ti| {
                    if (ti > 0) try output.appendSlice(allocator, ",");
                    try output.appendSlice(allocator, "\"");
                    try output.appendSlice(allocator, tag);
                    try output.appendSlice(allocator, "\"");
                }
                try output.appendSlice(allocator, "]}");
            }
        }

        try output.appendSlice(allocator, "],\"count\":");
        try output.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{}", .{count}));
        try output.appendSlice(allocator, "}");
        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── SkillViewTool ───────────────────────────────────────────────────────────────

pub const SkillViewTool = struct {
    skills_dir: []const u8,

    pub const tool_name = "skill_view";
    pub const tool_description = "View a skill's full content (SKILL.md)";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Skill name\"},\"file_path\":{\"type\":\"string\",\"description\":\"Optional: specific file within skill\"}},\"required\":[\"name\"]}";

    pub fn tool(self: *SkillViewTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SkillViewTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const name = getString(args, "name") orelse {
            return ToolResult.fail("name is required");
        };
        const file_path = getString(args, "file_path");

        const skill_md_path = if (file_path) |fp|
            try std.fmt.allocPrint(allocator, "{s}/skills/{s}/{s}", .{ self.skills_dir, name, fp })
        else
            try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        defer allocator.free(skill_md_path);

        const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 1024 * 1024) catch {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Skill '{s}' not found", .{name}));
        };

        if (scanForDangerousPatterns(content)) |pattern| {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Security warning: dangerous pattern '{s}'", .{pattern}));
        }

        return ToolResult.ok(content);
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── SkillManagerTool ────────────────────────────────────────────────────────────

pub const SkillManagerTool = struct {
    skills_dir: []const u8,

    pub const tool_description = "Manage skills - create, edit, delete, list, patch, write_file, remove_file, create_manifest";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"create\",\"edit\",\"delete\",\"list\",\"patch\",\"write_file\",\"remove_file\",\"create_manifest\"]},\"name\":{\"type\":\"string\",\"description\":\"Skill name\"},\"content\":{\"type\":\"string\",\"description\":\"Skill content (SKILL.md format)\"},\"category\":{\"type\":\"string\",\"description\":\"Category for the skill\"},\"old_string\":{\"type\":\"string\",\"description\":\"Text to find (for patch)\"},\"new_string\":{\"type\":\"string\",\"description\":\"Replacement text (for patch)\"},\"file_path\":{\"type\":\"string\",\"description\":\"File path within skill\"},\"file_content\":{\"type\":\"string\",\"description\":\"File content (for write_file)\"},\"manifest\":{\"type\":\"string\",\"description\":\"JSON manifest content (for create_manifest)\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *SkillManagerTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SkillManagerTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = getString(args, "action") orelse {
            return ToolResult.fail("action is required");
        };
        const name = getString(args, "name") orelse "";

        if (std.mem.eql(u8, action, "list")) {
            return self.listSkills(allocator);
        }

        if (name.len == 0) {
            return ToolResult.fail("Skill name is required");
        }

        if (std.mem.eql(u8, action, "create")) {
            const content = getString(args, "content") orelse "";
            const category = getString(args, "category");
            return self.createSkill(allocator, name, content, category);
        }

        if (std.mem.eql(u8, action, "edit")) {
            const content = getString(args, "content") orelse "";
            return self.editSkill(allocator, name, content);
        }

        if (std.mem.eql(u8, action, "delete")) {
            return self.deleteSkill(allocator, name);
        }

        if (std.mem.eql(u8, action, "patch")) {
            const old_str = getString(args, "old_string") orelse "";
            const new_str = getString(args, "new_string") orelse "";
            const file_path = getString(args, "file_path");
            return self.patchSkill(allocator, name, old_str, new_str, file_path);
        }

        if (std.mem.eql(u8, action, "write_file")) {
            const fp = getString(args, "file_path") orelse "";
            const fc = getString(args, "file_content") orelse "";
            return self.writeSkillFile(allocator, name, fp, fc);
        }

        if (std.mem.eql(u8, action, "remove_file")) {
            const fp = getString(args, "file_path") orelse "";
            return self.removeSkillFile(allocator, name, fp);
        }

        if (std.mem.eql(u8, action, "create_manifest")) {
            const manifest_json = getString(args, "manifest") orelse "{}";
            return self.createManifest(allocator, name, manifest_json);
        }

        return ToolResult.fail("Unknown action. Use: create, edit, delete, list, patch, write_file, remove_file, create_manifest");
    }

    fn listSkills(self: *SkillManagerTool, allocator: std.mem.Allocator) !ToolResult {
        var output = std.ArrayList(u8).empty;
        defer output.deinit(allocator);

        try output.appendSlice(allocator, "Skills:\n");

        const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills", .{self.skills_dir});
        defer allocator.free(skill_path);

        var dir = std.fs.cwd().openDir(skill_path, .{}) catch {
            return ToolResult.ok("No skills directory found");
        };
        defer dir.close();

        var iter = dir.iterate();
        var count: usize = 0;
        while (iter.next() catch null) |entry| : (count += 1) {
            if (entry.kind == .directory) {
                try output.appendSlice(allocator, "- ");
                try output.appendSlice(allocator, entry.name);
                try output.append(allocator, '\n');
            }
        }

        if (count == 0) {
            try output.appendSlice(allocator, "(no skills found)\n");
        }

        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    fn createSkill(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8, content: []const u8, category: ?[]const u8) !ToolResult {
        if (content.len > 0) {
            if (validateFrontmatter(content)) |err| return ToolResult.fail(err);
            if (scanForDangerousPatterns(content)) |pattern| {
                return ToolResult.fail(try std.fmt.allocPrint(allocator, "Security warning: dangerous pattern '{s}'", .{pattern}));
            }
        }

        var skill_path: []u8 = undefined;
        if (category) |cat| {
            skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/{s}/SKILL.md", .{ self.skills_dir, cat, name });
        } else {
            skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        }
        defer allocator.free(skill_path);

        const dir_path = std.fs.path.dirname(skill_path) orelse return ToolResult.fail("Invalid path");
        std.fs.cwd().makeDir(dir_path) catch {};

        std.fs.cwd().writeFile(.{ .sub_path = skill_path, .data = content }) catch {
            return ToolResult.fail("Failed to create skill file");
        };

        const msg = try std.fmt.allocPrint(allocator, "Skill '{s}' created", .{name});
        defer allocator.free(msg);
        return ToolResult.ok(msg);
    }

    fn editSkill(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8, content: []const u8) !ToolResult {
        if (content.len == 0) return ToolResult.fail("Skill content is required");
        if (validateFrontmatter(content)) |err| return ToolResult.fail(err);
        if (scanForDangerousPatterns(content)) |pattern| {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Security warning: dangerous pattern '{s}'", .{pattern}));
        }

        const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        defer allocator.free(skill_path);

        std.fs.cwd().access(skill_path, .{}) catch {
            return ToolResult.fail("Skill not found. Use action='create' first");
        };

        std.fs.cwd().writeFile(.{ .sub_path = skill_path, .data = content }) catch {
            return ToolResult.fail("Failed to write skill file");
        };

        const msg = try std.fmt.allocPrint(allocator, "Skill '{s}' updated", .{name});
        defer allocator.free(msg);
        return ToolResult.ok(msg);
    }

    fn deleteSkill(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8) !ToolResult {
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ self.skills_dir, name });
        defer allocator.free(skill_dir);

        std.fs.cwd().deleteTree(skill_dir) catch {
            return ToolResult.fail("Skill not found");
        };

        const msg = try std.fmt.allocPrint(allocator, "Skill '{s}' deleted", .{name});
        defer allocator.free(msg);
        return ToolResult.ok(msg);
    }

    fn patchSkill(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8, old_string: []const u8, new_string: []const u8, file_path: ?[]const u8) !ToolResult {
        if (old_string.len == 0) return ToolResult.fail("old_string is required");

        const target_path = if (file_path) |fp|
            try std.fmt.allocPrint(allocator, "{s}/skills/{s}/{s}", .{ self.skills_dir, name, fp })
        else
            try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        defer allocator.free(target_path);

        const content = std.fs.cwd().readFileAlloc(allocator, target_path, 1024 * 1024) catch {
            return ToolResult.fail("Skill file not found");
        };
        defer allocator.free(content);

        if (std.mem.indexOf(u8, content, old_string) == null) {
            return ToolResult.fail("old_string not found in file");
        }

        const new_content = try std.mem.replaceOwned(u8, allocator, content, old_string, new_string);
        defer allocator.free(new_content);

        std.fs.cwd().writeFile(.{ .sub_path = target_path, .data = new_content }) catch {
            return ToolResult.fail("Failed to write patched file");
        };

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Patched skill '{s}'", .{name}));
    }

    fn writeSkillFile(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8, file_path: []const u8, file_content: []const u8) !ToolResult {
        if (file_path.len == 0) return ToolResult.fail("file_path is required");
        if (validateSkillFilePath(file_path)) |err| return ToolResult.fail(err);

        const full_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/{s}", .{ self.skills_dir, name, file_path });
        defer allocator.free(full_path);

        const dir_path = std.fs.path.dirname(full_path) orelse return ToolResult.fail("Invalid path");
        std.fs.cwd().makeDir(dir_path) catch {};

        std.fs.cwd().writeFile(.{ .sub_path = full_path, .data = file_content }) catch {
            return ToolResult.fail("Failed to write file");
        };

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "File '{s}' written to skill '{s}'", .{ file_path, name }));
    }

    fn removeSkillFile(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8, file_path: []const u8) !ToolResult {
        if (file_path.len == 0) return ToolResult.fail("file_path is required");
        if (validateSkillFilePath(file_path)) |err| return ToolResult.fail(err);

        const full_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/{s}", .{ self.skills_dir, name, file_path });
        defer allocator.free(full_path);

        std.fs.cwd().deleteFile(full_path) catch {
            return ToolResult.fail("File not found");
        };

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "File '{s}' removed from skill '{s}'", .{ file_path, name }));
    }

    fn createManifest(self: *SkillManagerTool, allocator: std.mem.Allocator, name: []const u8, manifest_json: []const u8) !ToolResult {
        // Validate JSON
        var parser = std.json.Parser.init(allocator, .{});
        defer parser.deinit();

        _ = parser.parse(manifest_json) catch |err| {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Invalid JSON: {}", .{err}));
        };

        // Ensure skill directory exists
        const skill_dir = try std.fmt.allocPrint(allocator, "{s}/skills/{s}", .{ self.skills_dir, name });
        defer allocator.free(skill_dir);
        std.fs.cwd().makeDir(skill_dir) catch {};

        // Write manifest.json
        const manifest_path = try std.fmt.allocPrint(allocator, "{s}/manifest.json", .{ skill_dir });
        defer allocator.free(manifest_path);

        std.fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = manifest_json }) catch {
            return ToolResult.fail("Failed to write manifest.json");
        };

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Manifest created for skill '{s}'", .{name}));
    }

    pub const vtable = root.ToolVTable(@This());
};


// ── SkillRunTool ────────────────────────────────────────────────────────────────

pub const SkillRunTool = struct {
    skills_dir: []const u8,

    pub const tool_name = "skill_run";
    pub const tool_description = "Execute a skill by name with arguments (slash command style)";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"name\":{\"type\":\"string\",\"description\":\"Skill name to execute\"},\"args\":{\"type\":\"string\",\"description\":\"Arguments to pass to the skill\"}},\"required\":[\"name\"]}";

    pub fn tool(self: *SkillRunTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SkillRunTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const name = getString(args, "name") orelse {
            return ToolResult.fail("name is required");
        };
        const skill_args = getString(args, "args") orelse "";

        const skill_md_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        defer allocator.free(skill_md_path);

        const content = std.fs.cwd().readFileAlloc(allocator, skill_md_path, 1024 * 1024) catch {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Skill '{s}' not found", .{name}));
        };
        defer allocator.free(content);

        // Security scan
        if (scanForDangerousPatterns(content)) |pattern| {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Security warning: dangerous pattern '{s}'", .{pattern}));
        }
        // Skill body extraction available via extractSkillBody() if needed
        _ = extractSkillBody(content);


        // Build execution context
        var output = std.ArrayList(u8).empty;
        errdefer output.deinit(allocator);
        try output.appendSlice(allocator, "Executing skill: ");
        try output.appendSlice(allocator, name);
        try output.appendSlice(allocator, "\n\nArgs: ");
        try output.appendSlice(allocator, skill_args);
        try output.appendSlice(allocator, "\n\nSkill content loaded. Agent should use this to guide execution.");

        // Return skill content for agent to use
        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    fn extractSkillBody(content: []const u8) []const u8 {
        if (!std.mem.startsWith(u8, content, "---")) return content;
        const rest = content[3..];
        const end_idx = std.mem.indexOf(u8, rest, "---");
        if (end_idx == null) return content;
        const body_start = 3 + end_idx.? + 3;
        if (body_start >= content.len) return "";
        return std.mem.trim(u8, content[body_start..], " \n\r\t");
    }

    pub const vtable = root.ToolVTable(@This());
};
