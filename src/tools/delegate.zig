//! Delegate tools - spawn subagents for parallel task execution
//! Implements Tool vtable interface

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const getInt = root.getInt;

// ── DelegateTool ────────────────────────────────────────────────────────────────

pub const DelegateTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "delegate";
    pub const tool_description = "Delegate a task to a subagent for parallel execution";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"task_id\":{\"type\":\"string\",\"description\":\"Unique task identifier\"},\"prompt\":{\"type\":\"string\",\"description\":\"Task description for subagent\"},\"skills\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Skills to activate\"},\"timeout\":{\"type\":\"number\",\"description\":\"Timeout in seconds (default 60)\"}},\"required\":[\"prompt\"]}";

    pub fn tool(self: *DelegateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *DelegateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task_id = getString(args, "task_id") orelse "default";
        const prompt = getString(args, "prompt") orelse {
            return ToolResult.fail("prompt is required");
        };
        const timeout_secs: u32 = @intCast(getInt(args, "timeout") orelse 60);

        const delegate_dir = try std.fmt.allocPrint(allocator, "{s}/.delegate", .{self.workspace_dir});
        std.fs.cwd().makeDir(delegate_dir) catch {};
        allocator.free(delegate_dir);

        const task_file = try std.fmt.allocPrint(allocator, "{s}/.delegate/{s}.json", .{ self.workspace_dir, task_id });
        defer allocator.free(task_file);

        // Build JSON manually to avoid format string issues
        var json_buf = std.ArrayList(u8).empty;
        defer json_buf.deinit(allocator);
        const writer = json_buf.writer(allocator);

        try writer.writeAll("{\"task_id\": \"");
        try writer.writeAll(task_id);
        try writer.writeAll("\", \"prompt\": \"");
        try writer.writeAll(prompt);
        try writer.writeAll("\", \"status\": \"pending\", \"timeout\": ");
        try writer.print("{d}", .{timeout_secs});
        try writer.writeAll("}");

        const task_record = try json_buf.toOwnedSlice(allocator);
        defer allocator.free(task_record);

        std.fs.cwd().writeFile(.{ .sub_path = task_file, .data = task_record }) catch {
            return ToolResult.fail("Failed to create delegation record");
        };

        // Build success response
        var response_buf = std.ArrayList(u8).empty;
        defer response_buf.deinit(allocator);
        const response_writer = response_buf.writer(allocator);
        try response_writer.print(
            \\{\"success\":true,\"task_id\":\"{s}\",\"message\":\"Task delegated\",\"note\":\"Subagent execution requires async runtime\"}
        , .{task_id});

        return ToolResult.ok(try response_buf.toOwnedSlice(allocator));
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── DelegateResultTool ─────────────────────────────────────────────────────────

pub const DelegateResultTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "delegate_result";
    pub const tool_description = "Get results from a delegated subagent task";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"task_id\":{\"type\":\"string\",\"description\":\"Task ID returned by delegate()\"}},\"required\":[\"task_id\"]}";

    pub fn tool(self: *DelegateResultTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *DelegateResultTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task_id = getString(args, "task_id") orelse {
            return ToolResult.fail("task_id is required");
        };

        const task_file = try std.fmt.allocPrint(allocator, "{s}/.delegate/{s}.json", .{ self.workspace_dir, task_id });
        defer allocator.free(task_file);

        const content = std.fs.cwd().readFileAlloc(allocator, task_file, 1024 * 1024) catch {
            return ToolResult.fail("Task not found or not yet completed");
        };

        return ToolResult.ok(content);
    }

    pub const vtable = root.ToolVTable(@This());
};
