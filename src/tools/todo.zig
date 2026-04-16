//! Todo Tool - Task management for planning and tracking
//! Provides in-memory task list for decomposing complex tasks
//!
const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Valid status values for todo items
pub const VALID_STATUSES = &[_][]const u8{ "pending", "in_progress", "completed", "cancelled" };

/// A single todo item
pub const TodoItem = struct {
    id: []const u8,
    content: []const u8,
    status: []const u8,
};

/// Todo store for managing tasks
pub const TodoStore = struct {
    items: []TodoItem,

    pub fn init(_: std.mem.Allocator) TodoStore {
        return .{
            .items = &[_]TodoItem{},
        };
    }

    pub fn deinit(self: *TodoStore, allocator: std.mem.Allocator) void {
        for (self.items) |item| {
            allocator.free(item.id);
            allocator.free(item.content);
            allocator.free(item.status);
        }
        allocator.free(self.items);
    }

    /// Write todos - replace or merge
    pub fn write(self: *TodoStore, allocator: std.mem.Allocator, todos: []TodoItem, merge: bool) !void {
        if (!merge) {
            // Replace mode - clear existing items
            for (self.items) |item| {
                allocator.free(item.id);
                allocator.free(item.content);
                allocator.free(item.status);
            }
            allocator.free(self.items);

            // Clone all items
            var new_items = std.array_list.AlignedManaged(TodoItem, null).init(allocator);
            defer new_items.deinit();

            for (todos) |item| {
                const validated = validateItem(item, allocator);
                try new_items.append(validated);
            }

            self.items = try new_items.toOwnedSlice();
        } else {
            // Merge mode - update by id, append new
            var existing = std.StringArrayHashMap(usize).init(allocator);
            defer existing.deinit();

            // Index existing items by id
            for (self.items, 0..) |item, idx| {
                existing.put(item.id, idx) catch continue;
            }

            // Process incoming items
            for (todos) |item| {
                const item_id = item.id;
                if (existing.get(item_id)) |idx| {
                    // Update existing - only content and status
                    allocator.free(self.items[idx].content);
                    self.items[idx].content = try allocator.dupe(u8, item.content);
                    allocator.free(self.items[idx].status);
                    self.items[idx].status = try allocator.dupe(u8, item.status);
                } else {
                    // Add new item
                    const validated = validateItem(item, allocator);
                    try existing.put(item.id, self.items.len);
                    const new_items = try allocator.realloc(self.items, self.items.len + 1);
                    new_items[new_items.len - 1] = validated;
                    self.items = new_items;
                }
            }
        }
    }

    /// Read current todo list
    pub fn read(self: *TodoStore) []TodoItem {
        return self.items;
    }

    /// Format todos for context injection
    pub fn formatForInjection(self: *TodoStore, allocator: std.mem.Allocator) !?[]const u8 {
        if (self.items.len == 0) return null;

        // Only active items (pending/in_progress)
        var active_items = std.array_list.AlignedManaged(TodoItem, null).init(allocator);
        defer active_items.deinit();

        for (self.items) |item| {
            if (std.mem.eql(u8, item.status, "pending") or std.mem.eql(u8, item.status, "in_progress")) {
                try active_items.append(item);
            }
        }

        if (active_items.items.len == 0) return null;

        // Format as text
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll("[Your active task list was preserved]\n");

        for (active_items.items) |item| {
            const marker: []const u8 = if (std.mem.eql(u8, item.status, "in_progress")) "[>]" else "[ ]";
            try w.print("- {s} {s}. {s}\n", .{ marker, item.id, item.content });
        }

        return try buf.toOwnedSlice(allocator);
    }

    /// Validate and normalize a todo item
    fn validateItem(item: TodoItem, allocator: std.mem.Allocator) TodoItem {
        const id = if (item.id.len > 0) item.id else "?";
        const content = if (item.content.len > 0) item.content else "(no description)";

        var status = item.status;
        var valid = false;
        for (VALID_STATUSES) |s| {
            if (std.mem.eql(u8, item.status, s)) {
                valid = true;
                break;
            }
        }
        if (!valid) status = "pending";

        return .{
            .id = allocator.dupe(u8, id) catch id,
            .content = allocator.dupe(u8, content) catch content,
            .status = allocator.dupe(u8, status) catch status,
        };
    }
};

/// Parse todo items from JSON argument
fn parseTodoArgs(args: JsonObjectMap) ?[]TodoItem {
    _ = args;
    // For simplicity, return empty - full JSON parsing would require std.json
    return null;
}

/// TodoTool - Task management tool
pub const TodoTool = struct {
    store: TodoStore,

    pub const tool_name = "todo";
    pub const tool_description = "Manage your task list for the current session. Use for complex tasks with 3+ steps or when the user provides multiple tasks. Call with no parameters to read the current list.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"todos\":{\"type\":\"array\",\"description\":\"Task items to write\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"completed\",\"cancelled\"]}},\"required\":[\"id\",\"content\",\"status\"]}},\"merge\":{\"type\":\"boolean\",\"description\":\"true: update by id, false: replace\",\"default\":false}}}";

    pub fn init(allocator: std.mem.Allocator) TodoTool {
        return .{
            .store = TodoStore.init(allocator),
        };
    }

    pub fn deinit(self: *TodoTool, allocator: std.mem.Allocator) void {
        self.store.deinit(allocator);
    }

    pub fn tool(self: *TodoTool) Tool {
        return .{ .ptr = self, .vtable = &vtable };
    }

    pub fn execute(self: *TodoTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        // Get todos from args if provided
        const todos_arg = root.getString(args, "todos");
        _ = root.getBool(args, "merge") orelse false;

        if (todos_arg) |_| {
            // Would need JSON parsing - for now just return current state
        }

        // Return current state
        const items = self.store.read();

        // Count by status
        var pending: u32 = 0;
        var in_progress: u32 = 0;
        var completed: u32 = 0;
        var cancelled: u32 = 0;

        for (items) |item| {
            if (std.mem.eql(u8, item.status, "pending")) {
                pending += 1;
            } else if (std.mem.eql(u8, item.status, "in_progress")) {
                in_progress += 1;
            } else if (std.mem.eql(u8, item.status, "completed")) {
                completed += 1;
            } else if (std.mem.eql(u8, item.status, "cancelled")) {
                cancelled += 1;
            }
        }

        // Build JSON response
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"todos\":[");
        for (items, 0..) |item, i| {
            if (i > 0) try w.writeAll(",");
            try w.print("{\"id\":\"{s}\",\"content\":\"{s}\",\"status\":\"{s}\"}", .{ item.id, item.content, item.status });
        }
        try w.writeAll("],\"summary\":{");
        try w.print("\"total\":{d},\"pending\":{d},\"in_progress\":{d},\"completed\":{d},\"cancelled\":{d}", .{
            items.len, pending, in_progress, completed, cancelled,
        });
        try w.writeAll("}}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
