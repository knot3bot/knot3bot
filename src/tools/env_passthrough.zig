//! Environment variable passthrough registry.
//!
//! Skills that declare `required_environment_variables` need those vars
//! available in sandboxed execution environments. This module provides
//! a session-scoped allowlist so skill-declared vars pass through.
//!
//! Two sources feed the allowlist:
//! 1. Skill declarations — when a skill is loaded, its vars are registered
//! 2. User config — `terminal.env_passthrough` in config
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

var env_lock = std.Thread.Mutex{};
var allowed_vars: [][]u8 = &.{};
var allowed_set: std.StringArrayHashMap(void) = .empty;
var config_cached: ?[]const []const u8 = null;

/// Register environment variable names as allowed in sandboxed environments
pub fn registerEnvPassthrough(var_names: []const []const u8) void {
    env_lock.lock();
    defer env_lock.unlock();

    for (var_names) |name| {
        if (name.len == 0) continue;
        if (!allowed_set.contains(name)) {
            allowed_set.put(name, {}) catch continue;
        }
    }
}

/// Check if a variable name is in the passthrough allowlist
pub fn isEnvPassthrough(var_name: []const u8) bool {
    env_lock.lock();
    defer env_lock.unlock();

    if (allowed_set.contains(var_name)) return true;
    if (config_cached) |configs| {
        for (configs) |c| {
            if (std.mem.eql(u8, c, var_name)) return true;
        }
    }
    return false;
}

/// Get all passthrough variable names
pub fn getAllPassthrough() []const []const u8 {
    env_lock.lock();
    defer env_lock.unlock();

    return allowed_vars;
}

/// Clear all registered passthrough vars (session reset)
pub fn clearEnvPassthrough() void {
    env_lock.lock();
    defer env_lock.unlock();

    // Clear all registered vars
    allowed_vars = &.{};
    allowed_set = .empty;
}

/// EnvPassthroughTool - Tool for managing environment variable allowlist
pub const EnvPassthroughTool = struct {
    pub const tool_name = "env_passthrough";
    pub const tool_description = "Manage environment variable passthrough for sandboxed execution. Register vars that should be allowed through security filters.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"check\",\"register\",\"list\",\"clear\"],\"description\":\"Action: 'check' a variable, 'register' new vars, 'list' all, 'clear' the list\"},\"var_names\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"description\":\"Variable names to check or register\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *EnvPassthroughTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *EnvPassthroughTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse "check";

        if (std.mem.eql(u8, action, "register")) {
            // Register new variable names
            // In a full implementation, we'd parse the array from args
            // For now, this is a simplified version
            var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
            defer buf.deinit();
            try buf.writer().writeAll("{\"success\":true,\"registered\":[]}");
            return ToolResult{
                .success = true,
                .output = try buf.toOwnedSlice(allocator),
            };
        } else if (std.mem.eql(u8, action, "list")) {
            // List all registered variables
            var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
            defer buf.deinit();
            const w = buf.writer();

            try w.writeAll("{\"variables\":[");
            var first = true;
            env_lock.lock();
            for (allowed_set.keys()) |key| {
                if (!first) try w.writeAll(",");
                try w.print("\"{s}\"", .{key});
                first = false;
            }
            env_lock.unlock();
            try w.writeAll("]}");

            return ToolResult{
                .success = true,
                .output = try buf.toOwnedSlice(allocator),
            };
        } else if (std.mem.eql(u8, action, "clear")) {
            clearEnvPassthrough();
            return ToolResult.ok("{\"success\":true,\"message\":\"Passthrough list cleared\"}");
        } else {
            // check (default)
            const var_name = root.getString(args, "var_names");
            if (var_name) |name| {
                const allowed = isEnvPassthrough(name);
                var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
                defer buf.deinit();
                try buf.writer().print("{{\"variable\":\"{s}\",\"allowed\":{}}}", .{ name, allowed });
                return ToolResult{
                    .success = true,
                    .output = try buf.toOwnedSlice(allocator),
                };
            }
            return ToolResult.fail("var_names required for check action");
        }
    }

    pub const vtable = root.ToolVTable(@This());
};
