//! Interrupt signaling for long-running operations.
const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

var global_interrupt = std.atomic.Value(bool).init(false);

pub fn setInterrupt(active: bool) void { global_interrupt.store(active, .monotonic); }
pub fn isInterrupted() bool { return global_interrupt.load(.monotonic); }
pub fn clearInterrupt() void { global_interrupt.store(false, .monotonic); }

pub const InterruptTool = struct {
    pub const tool_name = "interrupt";
    pub const tool_description = "Check or set the execution interrupt flag for long-running operations.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"check\",\"set\",\"clear\"]}},\"required\":[\"action\"]}";

    pub fn tool(self: *InterruptTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *InterruptTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse "check";
        if (std.mem.eql(u8, action, "set")) { setInterrupt(true); return ToolResult.ok("{\"interrupted\":true}"); }
        if (std.mem.eql(u8, action, "clear")) { clearInterrupt(); return ToolResult.ok("{\"interrupted\":false}"); }
        const state = isInterrupted();
        const resp = try std.fmt.allocPrint(allocator, "{{\"interrupted\":{s}}}", .{if (state) "true" else "false"});
        return ToolResult.ok(resp);
    }

    pub const vtable = root.ToolVTable(@This());
};
