//! CLI platform adapter — connects the terminal UI to the gateway.
//!
//! Implements PlatformAdapter for CLI interactive mode.
//! Routes user input through gateway → agent → formatted terminal output.

const std = @import("std");
const gateway = @import("root.zig");
const display = @import("../display.zig");

pub const CliPlatform = struct {
    allocator: std.mem.Allocator,
    gw: *gateway.Gateway,

    pub fn init(allocator: std.mem.Allocator, gw: *gateway.Gateway) CliPlatform {
        return .{ .allocator = allocator, .gw = gw };
    }

    pub fn adapter(self: *CliPlatform) gateway.PlatformAdapter {
        return .{
            .ptr = @ptrCast(self),
            .onResponse = handleResponse,
            .onStreamChunk = handleStreamChunk,
            .onStreamEnd = handleStreamEnd,
            .onToolCall = handleToolCall,
        };
    }

    fn handleResponse(ptr: *anyopaque, response: gateway.Response) void {
        const self: *CliPlatform = @ptrCast(@alignCast(ptr));
        var d = display.Display.init(self.allocator);
        d.printHeader("Final Answer");
        std.debug.print("{s}\n\n", .{response.content});
        if (response.usage) |u| {
            d.printUsageStats(u.prompt_tokens, u.completion_tokens, 0);
        }
    }

    fn handleStreamChunk(ptr: *anyopaque, chunk: []const u8) void {
        _ = ptr;
        std.debug.print("{s}", .{chunk});
    }

    fn handleStreamEnd(ptr: *anyopaque, response: gateway.Response) void {
        _ = ptr;
        _ = response;
        std.debug.print("\n", .{});
    }

    fn handleToolCall(ptr: *anyopaque, tool_name: []const u8, args: []const u8, result: []const u8) void {
        _ = ptr;
        std.debug.print("{s}[Tool: {s}]{s}\n", .{ display.Colors.yellow, tool_name, display.Colors.reset });
        std.debug.print("  args: {s}\n", .{args});
        if (result.len > 200) {
            std.debug.print("  result: {s}...\n", .{result[0..200]});
        } else {
            std.debug.print("  result: {s}\n", .{result});
        }
    }
};
