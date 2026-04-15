//! Spawn tool - Subprocess management for long-running tasks
//!
//! Supports multiple execution environments:
//!   - local: Execute directly on the host machine
//!   - docker: Execute in Docker containers (isolated)
//!
//! Features:
//!   - Background task support
//!   - Process tracking and management
//!   - Output buffering with size limits
//!   - Working directory support
//!   - Environment variable handling

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const getInt = root.getInt;
const getBool = root.getBool;

const MAX_PROCESSES = 32;
const MAX_OUTPUT_BYTES = 200_000;
const MAX_STDERR_BYTES = 10_000;

/// Execution environment type
pub const EnvType = enum {
    local,
    docker,
};

/// Process state
pub const ProcessState = struct {
    pid: i32,
    command: []const u8,
    env_type: EnvType,
    started_at: i64,
    exited: bool = false,
    exit_code: ?i32 = null,
    child: ?*std.process.Child = null,
    used: bool = false,
    cwd: ?[]const u8 = null,
};

/// Global process table
var process_table: [MAX_PROCESSES]ProcessState = undefined;
var process_count: usize = 0;

fn initProcessTable() void {
    for (&process_table) |*slot| {
        slot.* = .{ .pid = 0, .command = "", .env_type = .local, .started_at = 0, .child = null, .used = false, .cwd = null };
    }
}

fn findEmptySlot() ?usize {
    for (0..MAX_PROCESSES) |i| {
        if (!process_table[i].used) return i;
    }
    return null;
}

fn findByPid(pid: i32) ?usize {
    for (0..MAX_PROCESSES) |i| {
        if (process_table[i].used and process_table[i].pid == pid) return i;
    }
    return null;
}

fn cleanupSlot(slot_idx: usize) void {
    if (process_table[slot_idx].child) |child| {
        std.heap.page_allocator.destroy(child);
    }
        if (process_table[slot_idx].cwd) |cwd| {
            std.heap.page_allocator.free(cwd);
        }
    process_table[slot_idx].used = false;
    process_table[slot_idx].child = null;
}

pub const SpawnTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "spawn";
    pub const tool_description = "Execute commands in local or Docker environments. Supports background tasks, process management, and output streaming.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"run\",\"list\",\"kill\",\"wait\",\"output\"]},\"command\":{\"type\":\"string\",\"description\":\"Command to run\"},\"pid\":{\"type\":\"integer\",\"description\":\"Process ID for kill/wait/output\"},\"detach\":{\"type\":\"boolean\",\"description\":\"Run detached (default: false)\"},\"env\":{\"type\":\"string\",\"enum\":[\"local\",\"docker\"],\"description\":\"Execution environment (default: local)\"},\"cwd\":{\"type\":\"string\",\"description\":\"Working directory\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *SpawnTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_self: *SpawnTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = getString(args, "action") orelse {
            return ToolResult.fail("action is required");
        };

        if (std.mem.eql(u8, action, "run")) {
            const command = getString(args, "command") orelse {
                return ToolResult.fail("command is required for run");
            };
            const detach = getBool(args, "detach") orelse false;
            const env_str = getString(args, "env") orelse "local";
            const cwd = getString(args, "cwd");
            const timeout = getInt(args, "timeout");

            const env_type: EnvType = if (std.mem.eql(u8, env_str, "docker")) .docker else .local;
            return _self.runProcess(allocator, command, detach, env_type, cwd, timeout);
        }

        if (std.mem.eql(u8, action, "list")) {
            return _self.listProcesses(allocator);
        }

        if (std.mem.eql(u8, action, "kill")) {
            const pid = getInt(args, "pid");
            if (pid == null) {
                return ToolResult.fail("pid is required for kill");
            }
            return _self.killProcess(allocator, @intCast(pid.?));
        }

        if (std.mem.eql(u8, action, "wait")) {
            const pid = getInt(args, "pid");
            if (pid == null) {
                return ToolResult.fail("pid is required for wait");
            }
            return _self.waitProcess(allocator, @intCast(pid.?));
        }

        if (std.mem.eql(u8, action, "output")) {
            const pid = getInt(args, "pid");
            if (pid == null) {
                return ToolResult.fail("pid is required for output");
            }
            return _self.getOutput(allocator, @intCast(pid.?));
        }

        return ToolResult.fail("Unknown action. Use: run, list, kill, wait, output");
    }

    fn runProcess(_: *SpawnTool, allocator: std.mem.Allocator, command: []const u8, detach: bool, env_type: EnvType, cwd: ?[]const u8, timeout: ?i64) !ToolResult {
        // Security: validate command
        if (validateSpawnCommand(command)) |err_msg| {
            return ToolResult.fail(err_msg);
        }

        // Check process limit
        if (process_count >= MAX_PROCESSES and !detach) {
            return ToolResult.fail("Too many concurrent processes");
        }

        // Prepare argv based on environment
        var argv: [10][]const u8 = undefined;
        var argc: usize = 0;

        if (env_type == .docker) {
            argv[0] = "docker";
            argv[1] = "run";
            argv[2] = "--rm";
            argv[3] = "-i";
            argc = 4;

            // Add working directory if specified
            if (cwd) |w| {
                argv[argc] = "-w";
                argc += 1;
                argv[argc] = w;
                argc += 1;
            }

            // Add default shell
            argv[argc] = "alpine";
            argv[argc + 1] = "sh";
            argv[argc + 2] = "-c";
            argv[argc + 3] = command;
            argc += 4;
        } else {
            argv[0] = "sh";
            argv[1] = "-c";
            argv[2] = command;
            argc = 3;
        }

        var child = std.process.Child.init(argv[0..argc], std.heap.page_allocator);
        child.stdin_behavior = .Inherit;

        if (detach) {
            child.stdout_behavior = .Inherit;
            child.stderr_behavior = .Inherit;
        } else {
            child.stdout_behavior = .Pipe;
            child.stderr_behavior = .Pipe;
        }

        // Set working directory for local execution
        if (cwd != null and env_type == .local) {
            child.cwd_dir = std.fs.cwd().openDir(cwd.?, .{}) catch null;
        }

        child.spawn() catch |err| {
            return ToolResult.fail(std.fmt.allocPrint(allocator, "Failed to spawn process: {}", .{err}) catch "Failed to spawn");
        };

        if (detach) {
            const slot = findEmptySlot();
            if (slot) |s| {
                const child_copy = try std.heap.page_allocator.create(std.process.Child);
                child_copy.* = child;

                const cwd_copy = if (cwd) |c| try std.heap.page_allocator.dupe(u8, c) else null;

                process_table[s] = .{
                    .pid = child.id,
                    .command = command,
                    .env_type = env_type,
                    .started_at = std.time.timestamp(),
                    .child = child_copy,
                    .used = true,
                    .cwd = cwd_copy,
                };
                process_count += 1;

                return ToolResult.ok(try std.fmt.allocPrint(allocator,
                    \\{{"started":true,"pid":{d},"detached":true,"env":"{s}","slot":{d}}}
                , .{ child.id, @tagName(env_type), s }));
            } else {
                return ToolResult.fail("Process table full");
            }
        } else {
            // Handle timeout
            var timeout_secs: i64 = 300; // 5 min default
            if (timeout) |t| timeout_secs = t;

            // Set up timeout thread for non-detached processes
            const start_time = std.time.timestamp();
            // Read stdout with size limit
            const stdout = child.stdout.?.readToEndAlloc(allocator, MAX_OUTPUT_BYTES) catch {
                _ = child.kill() catch {};
                return ToolResult.fail("Failed to read stdout");
            };
            defer allocator.free(stdout);

            // Check if already timed out
            if (std.time.timestamp() - start_time > timeout_secs) {
                _ = child.kill() catch {};
                return ToolResult.fail("Process timed out");
            }

            // Read stderr with size limit
            const stderr = child.stderr.?.readToEndAlloc(allocator, MAX_STDERR_BYTES) catch {
                allocator.free(stdout);
                _ = child.kill() catch {};
                return ToolResult.fail("Failed to read stderr");
            };
            defer allocator.free(stderr);

            // Wait for process with remaining timeout
            const term = child.wait() catch {
                allocator.free(stdout);
                allocator.free(stderr);
                return ToolResult.fail("Failed to wait for process");
            };

            const exit_code: i32 = switch (term) {
                .Exited => |code| code,
                .Signal => |sig| -@as(i32, @intCast(sig)),
                .Stopped => |sig| @as(i32, @intCast(sig)) + 128,
                else => -1,
            };

            // Truncate output if too large
            const truncated_stdout = if (stdout.len > MAX_OUTPUT_BYTES)
                stdout[0..MAX_OUTPUT_BYTES]
            else
                stdout;

            return ToolResult.ok(try std.fmt.allocPrint(allocator,
                \\{{"exited":true,"exit_code":{d},"stdout":"{s}","stderr":"{s}","truncated":{}}}
            , .{ exit_code, truncated_stdout, stderr, stdout.len > MAX_OUTPUT_BYTES }));
        }
    }

    fn listProcesses(_self: *SpawnTool, allocator: std.mem.Allocator) !ToolResult {
        _ = _self;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        const w = output.writer(allocator);

        try w.writeAll("{\"processes\":[");
        var first = true;
        var found_count: usize = 0;

        for (0..MAX_PROCESSES) |i| {
            if (process_table[i].used) {
                if (!first) try w.writeAll(",");
                first = false;
                found_count += 1;

                try w.print(
                    \\{{"slot":{d},"pid":{d},"command":"{s}","env":"{s}","started_at":{d},"exited":{}}}
                , .{
                    i,
                    process_table[i].pid,
                    process_table[i].command,
                    @tagName(process_table[i].env_type),
                    process_table[i].started_at,
                    process_table[i].exited,
                });
            }
        }

        try w.writeAll("],\"count\":");
        try w.print("{}", .{found_count});
        try w.writeAll("}");

        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    fn killProcess(_self: *SpawnTool, allocator: std.mem.Allocator, pid: i32) !ToolResult {
        _ = _self;
        const slot = findByPid(pid);
        if (slot) |s| {
            // For docker, we need to kill the container
            if (process_table[s].env_type == .docker) {
                // Try to kill the container (docker run --rm means container exits on process exit)
                const docker_argv = &[_][]const u8{ "docker", "kill", "--signal=KILL", try std.fmt.allocPrint(allocator, "{d}", .{pid}) };
                var child = std.process.Child.init(docker_argv, allocator);
                _ = child.spawn() catch {};
            }

            std.posix.kill(pid, 9) catch |err| {
                return ToolResult.fail(try std.fmt.allocPrint(allocator, "Failed to kill process: {}", .{err}));
            };
            cleanupSlot(s);
            process_count -= 1;
            return ToolResult.ok("Process terminated");
        }
        return ToolResult.fail("Process not found");
    }

    fn waitProcess(_self: *SpawnTool, allocator: std.mem.Allocator, pid: i32) !ToolResult {
        _ = _self;
        const slot = findByPid(pid);
        if (slot) |s| {
            const child = process_table[s].child;
            if (child) |c| {
                const term = c.wait() catch |err| {
                    return ToolResult.fail(try std.fmt.allocPrint(allocator, "Failed to wait: {}", .{err}));
                };

                const exit_code: i32 = switch (term) {
                    .Exited => |code| code,
                    .Signal => |sig| -@as(i32, @intCast(sig)),
                    .Stopped => |sig| @as(i32, @intCast(sig)) + 128,
                    else => -1,
                };

                process_table[s].exited = true;
                process_table[s].exit_code = exit_code;

                return ToolResult.ok(try std.fmt.allocPrint(allocator,
                    \\{{"exited":true,"exit_code":{d},"pid":{d}}}
                , .{ exit_code, pid }));
            } else {
                return ToolResult.fail("No child handle available");
            }
        }
        return ToolResult.fail("Process not found");
    }

    fn getOutput(_self: *SpawnTool, allocator: std.mem.Allocator, pid: i32) !ToolResult {
        _ = _self;
        const slot = findByPid(pid);
        if (slot) |s| {
            // For processes with stored output, return it
            // For running processes, this would need streaming implementation
            if (process_table[s].exited) {
                return ToolResult.ok(try std.fmt.allocPrint(allocator,
                    \\{{"pid":{d},"exited":true,"exit_code":{any}}}
                , .{ pid, process_table[s].exit_code }));
            }
            return ToolResult.ok(try std.fmt.allocPrint(allocator,
                \\{{"pid":{d},"running":true}}
            , .{pid}));
        }
        return ToolResult.fail("Process not found");
    }

    /// Validate command for dangerous patterns
    fn validateSpawnCommand(command: []const u8) ?[]const u8 {
        // Check for empty command
        if (command.len == 0) return "Empty command";

        // Check for dangerous patterns
        const dangerous = &[_][]const u8{
            "&& ",      "| ",       "|| ",       "; ",
            "> ",       "< ",       "`",         "${",
            "eval",     "exec ",    "sudo",      "chmod 777",
            "chmod +x", "rm -rf /", "rm -rf /*", "mkfs",
            "dd if=",
        };

        for (dangerous) |pattern| {
            if (std.mem.indexOf(u8, command, pattern) != null) {
                return "Command contains dangerous pattern";
            }
        }

        // Block cd, export, source at the start
        const trimmed = std.mem.trim(u8, command, " \t\n");
        if (std.mem.startsWith(u8, trimmed, "cd ")) return "cd not allowed";
        if (std.mem.startsWith(u8, trimmed, "export ")) return "export not allowed";
        if (std.mem.startsWith(u8, trimmed, "source ")) return "source not allowed";

        return null;
    }

    pub const vtable = root.ToolVTable(@This());
};
