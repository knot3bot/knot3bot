//! CheckpointManagerTool - Evolution state persistence
//! Implements Tool vtable interface

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;

// ── CheckpointManagerTool ────────────────────────────────────────────────────────

pub const CheckpointManagerTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "checkpoint";
    pub const tool_description = "Save or load agent evolution checkpoints for state persistence";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"save\",\"load\",\"list\",\"delete\"]},\"checkpoint_id\":{\"type\":\"string\",\"description\":\"Checkpoint identifier\"},\"state\":{\"type\":\"string\",\"description\":\"JSON state to save\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *CheckpointManagerTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *CheckpointManagerTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = getString(args, "action") orelse {
            return ToolResult.fail("action is required");
        };
        const checkpoint_id = getString(args, "checkpoint_id");
        const state = getString(args, "state");

        const checkpoint_dir = try std.fmt.allocPrint(allocator, "{s}/.checkpoints", .{self.workspace_dir});
        defer allocator.free(checkpoint_dir);

        std.fs.cwd().makeDir(checkpoint_dir) catch {};

        if (std.mem.eql(u8, action, "save")) {
            const cid = checkpoint_id orelse "default";
            const state_data = state orelse "{}";

            const checkpoint_file = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ checkpoint_dir, cid });
            defer allocator.free(checkpoint_file);

            std.fs.cwd().writeFile(.{ .sub_path = checkpoint_file, .data = state_data }) catch {
                return ToolResult.fail("Failed to save checkpoint");
            };

            // Build success response
            var response_buf = std.ArrayList(u8).empty;
            defer response_buf.deinit(allocator);
            const writer = response_buf.writer(allocator);
            try writer.print(
                \\{\"success\":true,\"checkpoint_id\":\"{s}\",\"message\":\"Checkpoint saved\"}
            , .{cid});

            return ToolResult.ok(try response_buf.toOwnedSlice(allocator));
        }

        if (std.mem.eql(u8, action, "load")) {
            const cid = checkpoint_id orelse return ToolResult.fail("checkpoint_id required for load");

            const checkpoint_file = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ checkpoint_dir, cid });
            defer allocator.free(checkpoint_file);

            const content = std.fs.cwd().readFileAlloc(allocator, checkpoint_file, 1024 * 1024) catch {
                return ToolResult.fail("Checkpoint not found");
            };

            return ToolResult.ok(content);
        }

        if (std.mem.eql(u8, action, "list")) {
            var dir = std.fs.cwd().openDir(checkpoint_dir, .{}) catch {
                return ToolResult.ok("{\"success\":true,\"checkpoints\":[]}");
            };
            defer dir.close();

            var output = std.ArrayList(u8).empty;
            defer output.deinit(allocator);
            try output.appendSlice(allocator, "{\"success\":true,\"checkpoints\":[");

            var first = true;
            var iter = dir.iterate();
            while (iter.next() catch null) |entry| {
                if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".json")) {
                    if (!first) try output.appendSlice(allocator, ",");
                    first = false;
                    const name = entry.name[0 .. entry.name.len - 5];
                    try output.appendSlice(allocator, "\"");
                    try output.appendSlice(allocator, name);
                    try output.appendSlice(allocator, "\"");
                }
            }

            try output.appendSlice(allocator, "]}");
            return ToolResult.ok(try output.toOwnedSlice(allocator));
        }

        if (std.mem.eql(u8, action, "delete")) {
            const cid = checkpoint_id orelse return ToolResult.fail("checkpoint_id required for delete");

            const checkpoint_file = try std.fmt.allocPrint(allocator, "{s}/{s}.json", .{ checkpoint_dir, cid });
            defer allocator.free(checkpoint_file);

            std.fs.cwd().deleteFile(checkpoint_file) catch {
                return ToolResult.fail("Checkpoint not found");
            };

            var response_buf = std.ArrayList(u8).empty;
            defer response_buf.deinit(allocator);
            const writer = response_buf.writer(allocator);
            try writer.print(
                \\{\"success\":true,\"checkpoint_id\":\"{s}\",\"message\":\"Checkpoint deleted\"}
            , .{cid});

            return ToolResult.ok(try response_buf.toOwnedSlice(allocator));
        }

        return ToolResult.fail("Unknown action. Use: save, load, list, delete");
    }

    pub const vtable = root.ToolVTable(@This());
};
