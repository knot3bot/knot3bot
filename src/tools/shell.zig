//! ShellTool - Execute shell commands
//! Implements Tool vtable interface

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const shared = @import("../shared/root.zig");

pub const ShellTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "shell";
    pub const tool_description = "Execute shell commands in the workspace";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"The shell command to execute\"}},\"required\":[\"command\"]}";

    pub fn tool(self: *ShellTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ShellTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const command = getString(args, "command") orelse {
            return ToolResult.fail("command is required");
        };

        if (validateCommand(command)) |err_msg| {
            return ToolResult.fail(err_msg);
        }

        const result = std.process.run(allocator, shared.context.io(), .{
            .argv = &[_][]const u8{ "/bin/sh", "-c", command },
            .cwd = .{ .path = self.workspace_dir },
        }) catch {
            return ToolResult.fail("Failed to execute command");
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);

        const exit_code: i32 = switch (result.term) {
            .exited => |code| code,
            .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
            .stopped => |sig| @as(i32, @intCast(@intFromEnum(sig))) + 128,
            else => -1,
        };

        if (exit_code == 0) {
            return ToolResult.ok(result.stdout);
        } else {
            const err_output = if (result.stderr.len > 0) result.stderr else try std.fmt.allocPrint(allocator, "Exit code: {d}", .{exit_code});
            return ToolResult.fail(err_output);
        }
    }

    fn validateCommand(command: []const u8) ?[]const u8 {
        const dangerous = &[_][]const u8{
            "&& ",  "| ",   "|| ", "; ",
            "> ",   "< ",   "`",   "$(",
            "eval", "exec",
        };
        for (dangerous) |pattern| {
            if (std.mem.indexOf(u8, command, pattern) != null) {
                return "Command contains blocked pattern";
            }
        }
        if (std.mem.indexOf(u8, command, "cd ") == 0) return "cd not allowed";
        if (std.mem.indexOf(u8, command, "export ") == 0) return "export not allowed";
        if (std.mem.indexOf(u8, command, "source ") == 0) return "source not allowed";
        return null;
    }

    pub const vtable = root.ToolVTable(@This());
};
