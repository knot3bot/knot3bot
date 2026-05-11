//! Delegate tools - spawn subagents for parallel task execution
const std = @import("std");
const root = @import("root.zig");
const shared = @import("../shared/context.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const getInt = root.getInt;

pub const DelegateTool = struct {
    workspace_dir: []const u8,
    pub const tool_name = "delegate";
    pub const tool_description = "Delegate a task to a subagent for parallel execution";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"task_id\":{\"type\":\"string\",\"description\":\"Unique task identifier\"},\"prompt\":{\"type\":\"string\",\"description\":\"Task description for subagent\"},\"skills\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Skills to activate\"},\"timeout\":{\"type\":\"number\",\"description\":\"Timeout in seconds (default 60)\"}},\"required\":[\"prompt\"]}";
    pub fn tool(self: *DelegateTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }

    pub fn execute(self: *DelegateTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task_id = getString(args, "task_id") orelse "default";
        const prompt = getString(args, "prompt") orelse return ToolResult.fail("prompt is required");
        const timeout_secs: u32 = @intCast(getInt(args, "timeout") orelse 60);

        const delegate_dir = try std.fmt.allocPrint(allocator, "{s}/.delegate", .{self.workspace_dir});
        shared.cwdMakePath(delegate_dir) catch {};
        allocator.free(delegate_dir);

        const task_file = try std.fmt.allocPrint(allocator, "{s}/.delegate/{s}.json", .{ self.workspace_dir, task_id });
        defer allocator.free(task_file);

        const task_record = try std.fmt.allocPrint(allocator,
            "{{\"task_id\":\"{s}\",\"prompt\":\"{s}\",\"status\":\"pending\",\"timeout\":{d}}}",
            .{ task_id, prompt, timeout_secs });
        defer allocator.free(task_record);
        shared.cwdWriteFile(task_file, task_record) catch return ToolResult.fail("Failed to create delegation record");

        const resp = try std.fmt.allocPrint(allocator,
            "{{\"success\":true,\"task_id\":\"{s}\",\"timeout\":{d},\"message\":\"Task delegated\",\"note\":\"Subagent execution requires async runtime\"}}",
            .{ task_id, timeout_secs });
        return ToolResult.ok(resp);
    }
    pub const vtable = root.ToolVTable(@This());
};

pub const DelegateResultTool = struct {
    workspace_dir: []const u8,
    pub const tool_name = "delegate_result";
    pub const tool_description = "Get results from a delegated subagent task";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"task_id\":{\"type\":\"string\",\"description\":\"Task ID returned by delegate()\"}},\"required\":[\"task_id\"]}";
    pub fn tool(self: *DelegateResultTool) Tool { return .{ .ptr = @ptrCast(self), .vtable = &vtable }; }

    pub fn execute(self: *DelegateResultTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const task_id = getString(args, "task_id") orelse return ToolResult.fail("task_id is required");
        const task_file = try std.fmt.allocPrint(allocator, "{s}/.delegate/{s}.json", .{ self.workspace_dir, task_id });
        defer allocator.free(task_file);
        const content = shared.cwdReadFileAlloc(allocator, task_file, 1024 * 1024) catch return ToolResult.fail("Task not found or not yet completed");
        return ToolResult.ok(content);
    }
    pub const vtable = root.ToolVTable(@This());
};
