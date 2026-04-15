//! Interrupt signaling for long-running operations.
//!
//! Provides a global interrupt flag that any tool can check to determine
//! if the user has requested an interrupt. The agent sets this flag,
//! and tools poll it during long-running operations.
//!
//! Usage in tools:
//!     if (interrupt.isInterrupted()) {
//!         return ToolResult.fail("interrupted");
//!     }
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Atomic interrupt state using a thread-local bool
/// In Zig, we use a struct with mutex for thread-safe access
pub const InterruptState = struct {
    interrupted: bool = false,
    lock: std.Thread.Mutex = .{},

    pub fn set(self: *InterruptState, active: bool) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.interrupted = active;
    }

    pub fn check(self: *InterruptState) bool {
        self.lock.lock();
        defer self.lock.unlock();
        return self.interrupted;
    }

    pub fn clear(self: *InterruptState) void {
        self.lock.lock();
        defer self.lock.unlock();
        self.interrupted = false;
    }
};

/// Global interrupt state
var global_interrupt = InterruptState{};

/// Set the interrupt flag
pub fn setInterrupt(active: bool) void {
    global_interrupt.set(active);
}

/// Check if interrupt has been requested
pub fn isInterrupted() bool {
    return global_interrupt.check();
}

/// Clear the interrupt flag
pub fn clearInterrupt() void {
    global_interrupt.clear();
}

/// InterruptTool - Tool for checking and managing interrupt state
pub const InterruptTool = struct {
    pub const tool_name = "interrupt";
    pub const tool_description = "Check or clear the global interrupt flag. Used to interrupt long-running operations.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"check\",\"clear\",\"set\"],\"description\":\"Action to perform: 'check' returns current state, 'clear' resets the flag, 'set' triggers interrupt\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *InterruptTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *InterruptTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse "check";

        if (std.mem.eql(u8, action, "clear")) {
            clearInterrupt();
            return ToolResult.ok("{\"interrupted\":false,\"message\":\"Interrupt flag cleared\"}");
        } else if (std.mem.eql(u8, action, "set")) {
            setInterrupt(true);
            return ToolResult.ok("{\"interrupted\":true,\"message\":\"Interrupt flag set\"}");
        } else {
            // check (default)
            const interrupted = isInterrupted();
            var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
            defer buf.deinit();
            try buf.writer().print("{{\"interrupted\":{},\"message\":\"Interrupt check\"}}", .{interrupted});
            return ToolResult{
                .success = true,
                .output = try buf.toOwnedSlice(allocator),
            };
        }
    }

    pub const vtable = root.ToolVTable(@This());
};
