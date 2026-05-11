//! Task Planner Tool — breaks complex tasks into subtasks and tracks progress.
//! Hermes Agent alignment: task planning + execution tracking.
//!
//! The planner maintains a session-scoped task list with status tracking:
//! pending → in_progress → completed | blocked | cancelled

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const MAX_TASKS = 50;
const MAX_TITLE_LEN = 256;

const TaskStatus = enum { pending, in_progress, completed, blocked, cancelled };

const PlannedTask = struct {
    id: u32,
    title: []u8,
    status: TaskStatus,
    depends_on: ?u32,
};

var tasks: [MAX_TASKS]PlannedTask = undefined;
var task_count: u32 = 0;
var next_id: u32 = 1;

pub const TaskPlannerTool = struct {
    pub const tool_name = "task_planner";
    pub const tool_description = "Plan and track complex multi-step tasks. Create subtasks, update status, list all tasks, or get a summary of progress.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"plan\",\"start\",\"complete\",\"block\",\"list\",\"summary\"]},\"task_id\":{\"type\":\"integer\",\"description\":\"Task ID to update\"},\"title\":{\"type\":\"string\",\"description\":\"Task title for plan action\"},\"depends_on\":{\"type\":\"integer\",\"description\":\"Optional: task ID this depends on\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *TaskPlannerTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *TaskPlannerTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse return ToolResult.fail("action required");

        if (std.mem.eql(u8, action, "plan")) {
            const title = root.getString(args, "title") orelse return ToolResult.fail("title required");
            if (task_count >= MAX_TASKS) return ToolResult.fail("task limit reached");
            if (title.len > MAX_TITLE_LEN) return ToolResult.fail("title too long");

            const title_copy = try allocator.dupe(u8, title);
            errdefer allocator.free(title_copy);

            const dep = if (root.getInt(args, "depends_on")) |d| @as(u32, @intCast(d)) else null;

            tasks[task_count] = .{
                .id = next_id,
                .title = title_copy,
                .status = .pending,
                .depends_on = dep,
            };
            next_id += 1;
            task_count += 1;

            const resp = try std.fmt.allocPrint(allocator, "{{\"created\":true,\"task_id\":{d},\"total_tasks\":{d}}}", .{ next_id - 1, task_count });
            return ToolResult.ok(resp);
        } else if (std.mem.eql(u8, action, "list")) {
            var buf = std.ArrayList(u8).initCapacity(allocator, 4096) catch return ToolResult.fail("OOM");
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, "{\"tasks\":[");
            var first = true;
            for (tasks[0..task_count]) |t| {
                if (!first) try buf.appendSlice(allocator, ",");
                first = false;
                const status_str = switch (t.status) {
                    .pending => "pending",
                    .in_progress => "in_progress",
                    .completed => "completed",
                    .blocked => "blocked",
                    .cancelled => "cancelled",
                };
                const entry = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"title\":\"{s}\",\"status\":\"{s}\"", .{ t.id, t.title, status_str });
                defer allocator.free(entry);
                try buf.appendSlice(allocator, entry);
                if (t.depends_on) |d| {
                    const dep = try std.fmt.allocPrint(allocator, ",\"depends_on\":{d}", .{d});
                    defer allocator.free(dep);
                    try buf.appendSlice(allocator, dep);
                }
                try buf.appendSlice(allocator, "}");
            }
            const footer = try std.fmt.allocPrint(allocator, "],\"count\":{d}}}", .{task_count});
            defer allocator.free(footer);
            try buf.appendSlice(allocator, footer);
            return ToolResult{ .success = true, .output = try buf.toOwnedSlice(allocator) };
        } else if (std.mem.eql(u8, action, "summary")) {
            var pending: u32 = 0;
            var in_progress: u32 = 0;
            var completed: u32 = 0;
            var blocked: u32 = 0;
            for (tasks[0..task_count]) |t| {
                switch (t.status) {
                    .pending => pending += 1,
                    .in_progress => in_progress += 1,
                    .completed => completed += 1,
                    .blocked => blocked += 1,
                    .cancelled => {},
                }
            }
            const progress = if (task_count > 0) @as(f32, @floatFromInt(completed)) / @as(f32, @floatFromInt(task_count)) * 100.0 else 0.0;
            const resp = try std.fmt.allocPrint(allocator,
                "{{\"total\":{d},\"pending\":{d},\"in_progress\":{d},\"completed\":{d},\"blocked\":{d},\"progress_pct\":{d:.1}}}",
                .{ task_count, pending, in_progress, completed, blocked, progress });
            return ToolResult.ok(resp);
        } else {
            const task_id = if (root.getInt(args, "task_id")) |id| @as(u32, @intCast(id)) else return ToolResult.fail("task_id required");
            var found: ?*PlannedTask = null;
            for (tasks[0..task_count]) |*t| {
                if (t.id == task_id) { found = t; break; }
            }
            const t = found orelse return ToolResult.fail("task not found");

            if (std.mem.eql(u8, action, "start")) {
                t.status = .in_progress;
            } else if (std.mem.eql(u8, action, "complete")) {
                t.status = .completed;
            } else if (std.mem.eql(u8, action, "block")) {
                t.status = .blocked;
            } else {
                return ToolResult.fail("unknown action");
            }
            const resp = try std.fmt.allocPrint(allocator, "{{\"updated\":true,\"task_id\":{d}}}", .{task_id});
            return ToolResult.ok(resp);
        }
    }

    pub const vtable = root.ToolVTable(@This());
};
