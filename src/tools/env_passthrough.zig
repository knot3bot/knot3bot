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

var env_lock = std.Io.Mutex.init;
const env_io = std.Io.Threaded.global_single_threaded.io();
var allowed_vars: [][]u8 = &.{};
var allowed_set: std.StringHashMap(void) = std.StringHashMap(void).init(std.heap.page_allocator);
var config_cached: ?[]const []const u8 = null;

/// Register environment variable names as allowed in sandboxed environments
pub fn registerEnvPassthrough(var_names: []const []const u8) void {
    env_lock.lockUncancelable(env_io);
    defer env_lock.unlock(env_io);

    for (var_names) |name| {
        if (name.len == 0) continue;
        if (!allowed_set.contains(name)) {
            allowed_set.put(name, {}) catch continue;
        }
    }
}

/// Check if a variable name is in the passthrough allowlist
pub fn isEnvPassthrough(var_name: []const u8) bool {
    env_lock.lockUncancelable(env_io);
    defer env_lock.unlock(env_io);

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
    env_lock.lockUncancelable(env_io);
    defer env_lock.unlock(env_io);

    return allowed_vars;
}

/// Clear all registered passthrough vars (session reset)
pub fn clearEnvPassthrough() void {
    env_lock.lockUncancelable(env_io);
    defer env_lock.unlock(env_io);

    // Clear all registered vars
    allowed_vars = &.{};
    allowed_set.clearRetainingCapacity();
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
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);
            try buf.appendSlice(allocator, "{\"success\":true,\"registered\":[]}");
            return ToolResult{
                .success = true,
                .output = try buf.toOwnedSlice(allocator),
            };
        } else if (std.mem.eql(u8, action, "list")) {
            var buf: std.ArrayList(u8) = .empty;
            defer buf.deinit(allocator);

            try buf.appendSlice(allocator, "{\"variables\":[");
            var first = true;
            env_lock.lockUncancelable(env_io);
            var key_iter = allowed_set.keyIterator();
            while (key_iter.next()) |key_ptr| {
                if (!first) try buf.appendSlice(allocator, ",");
                const ks = try std.fmt.allocPrint(allocator, "\"{s}\"", .{key_ptr.*});
                defer allocator.free(ks);
                try buf.appendSlice(allocator, ks);
                first = false;
            }
            env_lock.unlock(env_io);
            try buf.appendSlice(allocator, "]}");

            return ToolResult{
                .success = true,
                .output = try buf.toOwnedSlice(allocator),
            };
        } else if (std.mem.eql(u8, action, "clear")) {
            clearEnvPassthrough();
            return ToolResult.ok("{\"success\":true,\"message\":\"Passthrough list cleared\"}");
        } else {
            const var_name = root.getString(args, "var_names");
            if (var_name) |name| {
                const allowed = isEnvPassthrough(name);
                var buf: std.ArrayList(u8) = .empty;
                defer buf.deinit(allocator);
                const result = try std.fmt.allocPrint(allocator, "{{\"variable\":\"{s}\",\"allowed\":{}}}", .{ name, allowed });
                defer allocator.free(result);
                try buf.appendSlice(allocator, result);
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
