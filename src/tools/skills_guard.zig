//! SkillsGuard tool - Security scanner for skills
//!
//! Scans content for dangerous patterns, validates frontmatter and file paths

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;

// Security patterns to detect prompt injection attacks
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

const ALLOWED_SUBDIRS = [_][]const u8{ "references", "templates", "scripts", "assets" };

fn scanForDangerousPatterns(content: []const u8) ?[]const u8 {
    inline for (DANGEROUS_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, content, pattern) != null) {
            return pattern;
        }
    }
    return null;
}

fn validateFrontmatter(content: []const u8) ?[]const u8 {
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

fn validateSkillFilePath(file_path: []const u8) ?[]const u8 {
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

pub const SkillsGuardTool = struct {
    skills_dir: []const u8,

    pub const tool_name = "skills_guard";
    pub const tool_description = "Security scanner for skills - scan content for dangerous patterns, validate frontmatter, check file paths";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"scan_content\",\"validate_frontmatter\",\"check_path\",\"full_audit\"]},\"content\":{\"type\":\"string\",\"description\":\"Content to scan for dangerous patterns\"},\"frontmatter\":{\"type\":\"string\",\"description\":\"Frontmatter to validate\"},\"file_path\":{\"type\":\"string\",\"description\":\"File path to validate\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *SkillsGuardTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SkillsGuardTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = self;
        const action = getString(args, "action") orelse {
            return ToolResult.fail("action is required");
        };

        if (std.mem.eql(u8, action, "scan_content")) {
            const content = getString(args, "content") orelse {
                return ToolResult.fail("content is required for scan_content");
            };
            return scanContent(allocator, content);
        }

        if (std.mem.eql(u8, action, "validate_frontmatter")) {
            const frontmatter = getString(args, "frontmatter") orelse {
                return ToolResult.fail("frontmatter is required for validate_frontmatter");
            };
            return validateFrontmatterResult(allocator, frontmatter);
        }

        if (std.mem.eql(u8, action, "check_path")) {
            const file_path = getString(args, "file_path") orelse {
                return ToolResult.fail("file_path is required for check_path");
            };
            return checkPathResult(allocator, file_path);
        }

        if (std.mem.eql(u8, action, "full_audit")) {
            return fullAudit(allocator);
        }

        return ToolResult.fail("Unknown action. Use: scan_content, validate_frontmatter, check_path, full_audit");
    }

    fn scanContent(allocator: std.mem.Allocator, content: []const u8) !ToolResult {
        if (scanForDangerousPatterns(content)) |pattern| {
            const json = try std.fmt.allocPrint(allocator, "{{\\\"dangerous\\\":true,\\\"pattern\\\":\\\"{s}\\\",\\\"severity\\\":\\\"critical\\\"}}", .{pattern});
            return ToolResult.ok(json);
        }
        return ToolResult.ok("{{\\\"dangerous\\\":false,\\\"pattern\\\":null,\\\"severity\\\":null}}");
    }

    fn validateFrontmatterResult(allocator: std.mem.Allocator, content: []const u8) !ToolResult {
        if (validateFrontmatter(content)) |err| {
            const json = try std.fmt.allocPrint(allocator, "{{\\\"valid\\\":false,\\\"error\\\":\\\"{s}\\\"}}", .{err});
            return ToolResult.ok(json);
        }
        return ToolResult.ok("{{\\\"valid\\\":true,\\\"error\\\":null}}");
    }

    fn checkPathResult(allocator: std.mem.Allocator, file_path: []const u8) !ToolResult {
        if (validateSkillFilePath(file_path)) |err| {
            const json = try std.fmt.allocPrint(allocator, "{{\\\"valid\\\":false,\\\"error\\\":\\\"{s}\\\"}}", .{err});
            return ToolResult.ok(json);
        }
        return ToolResult.ok("{{\\\"valid\\\":true,\\\"error\\\":null}}");
    }

    fn fullAudit(allocator: std.mem.Allocator) !ToolResult {
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        try output.appendSlice(allocator, "audit");
        try output.appendSlice(allocator, " patterns:");
        try output.appendSlice(allocator, try std.fmt.allocPrint(allocator, " {d} dangerous patterns", .{DANGEROUS_PATTERNS.len}));

        try output.appendSlice(allocator, ", allowed dirs: ");
        inline for (ALLOWED_SUBDIRS, 0..) |subdir, i| {
            if (i > 0) try output.appendSlice(allocator, ", ");
            try output.appendSlice(allocator, subdir);
        }

        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    pub const vtable = root.ToolVTable(@This());
};
