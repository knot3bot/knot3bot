//! Skill Self-Improve Tool
//!
//! Implements the action side of the self-improvement loop:
//! - Creates skills from successful task patterns
//! - Patches existing skills based on failure feedback
//! - Updates USER.md/MEMORY.md with facts and preferences

const std = @import("std");
const root = @import("root.zig");

const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;

/// Skill content template generator
pub fn generateSkillTemplate(tool_name: []const u8, _: []const u8, success_count: u32) []const u8 {
    if (tool_name.len == 0) return "";

    return std.fmt.comptimePrint(
        \\---
        \\name: {s}-workflow
        \\description: Automated workflow from {d} successful executions
        \\---
        \\
        \\# {s} Workflow
        \\
        \\## When to Use
        \\Tasks requiring {s} operations.
        \\
        \\## Steps
        \\1. Identify {s} operation needed
        \\2. Execute with {s} tool
        \\3. Verify result
        \\
        \\## Notes
        \\Auto-generated from usage patterns.
        \\
    , .{ tool_name, success_count, tool_name, tool_name, tool_name, tool_name });
}

/// SkillSelfImproveTool - acts on self-improvement suggestions
pub const SkillSelfImproveTool = struct {
    skills_dir: []const u8,
    memory_dir: []const u8,

    pub const tool_name = "skill_self_improve";
    pub const tool_description = "Create skills from patterns, patch skills, update memory";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"create_skill\",\"patch_skill\",\"update_memory\",\"log_improvement\",\"get_suggestions\"]},\"skill_name\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"old_string\":{\"type\":\"string\"},\"new_string\":{\"type\":\"string\"},\"memory_type\":{\"type\":\"string\"},\"memory_content\":{\"type\":\"string\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *SkillSelfImproveTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *SkillSelfImproveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = getString(args, "action") orelse {
            return ToolResult.fail("action is required");
        };

        if (std.mem.eql(u8, action, "create_skill")) {
            return self.createSkillFromSuggestion(allocator, args);
        }
        if (std.mem.eql(u8, action, "patch_skill")) {
            return self.patchSkillFromSuggestion(allocator, args);
        }
        if (std.mem.eql(u8, action, "update_memory")) {
            return self.updateMemory(allocator, args);
        }
        if (std.mem.eql(u8, action, "log_improvement")) {
            return self.logImprovement(allocator, args);
        }
        if (std.mem.eql(u8, action, "get_suggestions")) {
            return self.getSuggestions(allocator);
        }

        return ToolResult.fail("Unknown action");
    }

    fn createSkillFromSuggestion(self: *SkillSelfImproveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const name = getString(args, "skill_name") orelse {
            return ToolResult.fail("skill_name is required");
        };
        const content = getString(args, "content") orelse "";

        if (content.len > 0 and scanForDangerousPatterns(content)) |pattern| {
            return ToolResult.fail(try std.fmt.allocPrint(allocator, "Security: dangerous pattern '{s}'", .{pattern}));
        }

        const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        defer allocator.free(skill_path);

        const dir_path = std.fs.path.dirname(skill_path) orelse return ToolResult.fail("Invalid path");
        std.fs.cwd().makeDir(dir_path) catch {};

        std.fs.cwd().writeFile(.{ .sub_path = skill_path, .data = content }) catch {
            return ToolResult.fail("Failed to create skill");
        };

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Skill '{s}' created", .{name}));
    }

    fn patchSkillFromSuggestion(self: *SkillSelfImproveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const name = getString(args, "skill_name") orelse return ToolResult.fail("skill_name required");
        const old_str = getString(args, "old_string") orelse return ToolResult.fail("old_string required");
        const new_str = getString(args, "new_string") orelse "";

        const skill_path = try std.fmt.allocPrint(allocator, "{s}/skills/{s}/SKILL.md", .{ self.skills_dir, name });
        defer allocator.free(skill_path);

        const content = std.fs.cwd().readFileAlloc(allocator, skill_path, 1024 * 1024) catch {
            return ToolResult.fail("Skill not found");
        };
        defer allocator.free(content);

        if (std.mem.indexOf(u8, content, old_str) == null) {
            return ToolResult.fail("old_string not found");
        }

        const new_content = try std.mem.replaceOwned(u8, allocator, content, old_str, new_str);
        defer allocator.free(new_content);

        try std.fs.cwd().writeFile(.{ .sub_path = skill_path, .data = new_content });

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Skill '{s}' patched", .{name}));
    }

    fn updateMemory(self: *SkillSelfImproveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const memory_type = getString(args, "memory_type") orelse "USER.md";
        const memory_content = getString(args, "memory_content") orelse {
            return ToolResult.fail("memory_content required");
        };

        if (!std.mem.eql(u8, memory_type, "USER.md") and !std.mem.eql(u8, memory_type, "MEMORY.md")) {
            return ToolResult.fail("memory_type must be USER.md or MEMORY.md");
        }

        const memory_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.memory_dir, memory_type });
        defer allocator.free(memory_path);

        const existing_err = std.fs.cwd().readFileAlloc(allocator, memory_path, 1024 * 1024);
        const existing: []u8 = if (existing_err) |data| data else "";
        defer if (existing.len > 0) allocator.free(existing);

        const timestamp = std.time.timestamp();
        const new_entry = try std.fmt.allocPrint(allocator, "\n---\n{d} | user\n---\n{s}\n", .{ timestamp, memory_content });

        const updated = if (existing.len > 0)
            try std.mem.concat(allocator, u8, &.{ existing, new_entry })
        else
            new_entry;
        defer allocator.free(updated);


        return ToolResult.ok(try std.fmt.allocPrint(allocator, "Updated {s}", .{memory_type}));
    }

    fn logImprovement(self: *SkillSelfImproveTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const skill_name = getString(args, "skill_name") orelse "unknown";
        const memory_content = getString(args, "memory_content") orelse "";

        const log_path = try std.fmt.allocPrint(allocator, "{s}/skill-improvements.md", .{self.memory_dir});
        defer allocator.free(log_path);

        const timestamp = std.time.timestamp();
        const entry = try std.fmt.allocPrint(allocator, "\n## {d} - {s}\n{s}\n", .{ timestamp, skill_name, memory_content });
        defer allocator.free(entry);

        const file = std.fs.cwd().openFile(log_path, .{ .mode = .append_only }) catch {
            return ToolResult.fail("Failed to open log");
        };
        defer file.close();

        file.writeAll(entry) catch return ToolResult.fail("Failed to write log");
        return ToolResult.ok("Improvement logged");
    }

    fn getSuggestions(self: *SkillSelfImproveTool, allocator: std.mem.Allocator) !ToolResult {
        // Try to read suggestions from the file written by SkillSelfImprove engine
        const suggestions_path = try std.fmt.allocPrint(allocator, "{s}/skill-suggestions.json", .{self.memory_dir});
        defer allocator.free(suggestions_path);

        const content = std.fs.cwd().readFileAlloc(allocator, suggestions_path, 4096) catch {
            return ToolResult.ok("No suggestions yet. Skill Self-Improvement is active. Use create_skill, patch_skill, or update_memory actions to improve the skill system.");
        };
        defer allocator.free(content);

        return ToolResult.ok(content);
    }

    pub const vtable = root.ToolVTable(@This());
};

fn scanForDangerousPatterns(content: []const u8) ?[]const u8 {
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

    inline for (DANGEROUS_PATTERNS) |pattern| {
        if (std.mem.indexOf(u8, content, pattern) != null) {
            return pattern;
        }
    }
    return null;
}