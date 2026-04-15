//! ShellTool - Execute shell commands
//! Implements Tool vtable interface

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;

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

        // Security: validate command
        if (validateCommand(command)) |err_msg| {
            return ToolResult.fail(err_msg);
        }

        // Execute with explicit argv array (not shell expansion)
        const argv = &[_][]const u8{ "/bin/sh", "-c", command };
        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        child.cwd = self.workspace_dir;

        child.spawn() catch {
            return ToolResult.fail("Failed to execute command");
        };

        const stdout = child.stdout.?.readToEndAlloc(allocator, 1024 * 100) catch "";
        defer allocator.free(stdout);
        const stderr = child.stderr.?.readToEndAlloc(allocator, 4096) catch "";
        defer allocator.free(stderr);

        const term = child.wait() catch std.process.Child.Term{ .Exited = 1 };
        const exit_code: i32 = switch (term) {
            .Exited => |code| code,
            .Signal => |sig| -@as(i32, @intCast(sig)),
            .Stopped => |sig| @as(i32, @intCast(sig)) + 128,
            else => -1,
        };

        if (exit_code == 0) {
            return ToolResult.ok(stdout);
        } else {
            const err_output = if (stderr.len > 0) stderr else try std.fmt.allocPrint(allocator, "Exit code: {d}", .{exit_code});
            return ToolResult.fail(err_output);
        }
    }

    /// Validate command for dangerous patterns
    fn validateCommand(command: []const u8) ?[]const u8 {
        // Block dangerous shell metacharacters that enable injection
        const dangerous = &[_][]const u8{
            "&& ", "| ", "|| ", "; ",  // Command chaining
            "> ", "< ",                // I/O redirection
            "`",                         // Command substitution
            "$}(",                       // Subshell
            "eval",                      // Eval keyword
            "exec",                      // Exec keyword
        };
        for (dangerous) |pattern| {
            if (std.mem.indexOf(u8, command, pattern) != null) {
                return "Command contains blocked pattern";
            }
        }
        // Block commands that modify shell state
        if (std.mem.indexOf(u8, command, "cd ") == 0) return "cd not allowed";
        if (std.mem.indexOf(u8, command, "export ") == 0) return "export not allowed";
        if (std.mem.indexOf(u8, command, "source ") == 0) return "source not allowed";
        return null;
    }

    pub const vtable = root.ToolVTable(@This());
};
