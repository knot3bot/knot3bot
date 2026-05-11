//! Diff Tool — unified diff generation and application.
//! Hermes Agent alignment: programmatic code change tool.
//!
//! Two actions:
//! - diff: generate unified diff between two strings
//! - apply: apply a unified diff patch to a file

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

pub const DiffTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "diff";
    pub const tool_description = "Generate unified diffs between file versions or strings. Apply patches to files in the workspace.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"diff\",\"apply\"],\"description\":\"diff: compare two strings/files, apply: patch a file\"},\"original\":{\"type\":\"string\",\"description\":\"Original content or file path for diff\"},\"modified\":{\"type\":\"string\",\"description\":\"Modified content for diff\"},\"patch\":{\"type\":\"string\",\"description\":\"Unified diff to apply\"},\"file_path\":{\"type\":\"string\",\"description\":\"Target file for apply action\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *DiffTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *DiffTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse return ToolResult.fail("action required");

        if (std.mem.eql(u8, action, "diff")) {
            const original = root.getString(args, "original") orelse return ToolResult.fail("original required");
            const modified = root.getString(args, "modified") orelse return ToolResult.fail("modified required");
            return generateDiff(allocator, original, modified);
        } else if (std.mem.eql(u8, action, "apply")) {
            const patch = root.getString(args, "patch") orelse return ToolResult.fail("patch required");
            const file_path = root.getString(args, "file_path") orelse return ToolResult.fail("file_path required");
            return applyPatch(allocator, self.workspace_dir, file_path, patch);
        }
        return ToolResult.fail("unknown action");
    }

    fn generateDiff(allocator: std.mem.Allocator, original: []const u8, modified: []const u8) !ToolResult {
        var buf = std.ArrayList(u8).initCapacity(allocator, 8192) catch return ToolResult.fail("OOM");
        defer buf.deinit(allocator);

        const orig_lines = splitLines(allocator, original);
        defer allocator.free(orig_lines);
        const mod_lines = splitLines(allocator, modified);
        defer allocator.free(mod_lines);

        const header = try std.fmt.allocPrint(allocator, "--- original\n+++ modified\n@@ -1,{d} +1,{d} @@\n", .{ orig_lines.len, mod_lines.len });
        defer allocator.free(header);
        try buf.appendSlice(allocator, header);

        var i: usize = 0;
        while (i < orig_lines.len or i < mod_lines.len) : (i += 1) {
            const o = if (i < orig_lines.len) orig_lines[i] else "";
            const m = if (i < mod_lines.len) mod_lines[i] else "";
            if (std.mem.eql(u8, o, m)) {
                const line = try std.fmt.allocPrint(allocator, " {s}\n", .{o});
                defer allocator.free(line);
                try buf.appendSlice(allocator, line);
            } else {
                if (o.len > 0) {
                    const line = try std.fmt.allocPrint(allocator, "-{s}\n", .{o});
                    defer allocator.free(line);
                    try buf.appendSlice(allocator, line);
                }
                if (m.len > 0) {
                    const line = try std.fmt.allocPrint(allocator, "+{s}\n", .{m});
                    defer allocator.free(line);
                    try buf.appendSlice(allocator, line);
                }
            }
        }
        return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
    }

    fn applyPatch(allocator: std.mem.Allocator, workspace: []const u8, file_path: []const u8, patch: []const u8) !ToolResult {
        _ = patch;
        // For a complete implementation: parse the unified diff hunks and apply to the file.
        // This requires proper diff parsing and hunk application logic.
        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ workspace, file_path });
        defer allocator.free(full_path);

        const response = try std.fmt.allocPrint(allocator,
            "{{\"applied\":false,\"reason\":\"patch parsing not yet implemented\",\"file\":\"{s}\"}}",
            .{full_path});
        return ToolResult.ok(response);
    }

    fn splitLines(allocator: std.mem.Allocator, text: []const u8) [][]const u8 {
        var list = std.ArrayList([]const u8).initCapacity(allocator, 64) catch return &.{};
        var iter = std.mem.splitScalar(u8, text, '\n');
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, "\r");
            list.append(allocator, trimmed) catch break;
        }
        return list.toOwnedSlice(allocator) catch &.{};
    }

    pub const vtable = root.ToolVTable(@This());
};
