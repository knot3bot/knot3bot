//! Spawn tool - Subprocess management for long-running tasks
//!
//! Supports multiple execution environments:
//!   - local: Execute directly on the host machine
//!   - docker: Execute in Docker containers (isolated)

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const getInt = root.getInt;
const getBool = root.getBool;
const shared = @import("../shared/root.zig");

const MAX_PROCESSES = 32;
const MAX_OUTPUT_BYTES = 200_000;
const MAX_STDERR_BYTES = 10_000;

pub const EnvType = enum {
    local,
    docker,
};

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
        if (validateSpawnCommand(command)) |err_msg| {
            return ToolResult.fail(err_msg);
        }

        if (process_count >= MAX_PROCESSES and !detach) {
            return ToolResult.fail("Too many concurrent processes");
        }

        var argv: [10][]const u8 = undefined;
        var argc: usize = 0;

        if (env_type == .docker) {
            argv[0] = "docker";
            argv[1] = "run";
            argv[2] = "--rm";
            argv[3] = "-i";
            argc = 4;

            if (cwd) |w| {
                argv[argc] = "-w";
                argc += 1;
                argv[argc] = w;
                argc += 1;
            }

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

        if (detach) {
            const child = std.process.spawn(shared.context.io(), .{
                .argv = argv[0..argc],
                .stdin = .inherit,
                .stdout = .inherit,
                .stderr = .inherit,
                .cwd = if (cwd != null and env_type == .local) .{ .path = cwd.? } else .inherit,
            }) catch |err| {
                return ToolResult.fail(std.fmt.allocPrint(allocator, "Failed to spawn process: {}", .{err}) catch "Failed to spawn");
            };

            const slot = findEmptySlot();
            if (slot) |s| {
                const child_copy = try std.heap.page_allocator.create(std.process.Child);
                child_copy.* = child;

                const cwd_copy = if (cwd) |c| try std.heap.page_allocator.dupe(u8, c) else null;

                const pid = child.id orelse return ToolResult.fail("Failed to get process ID");
                process_table[s] = .{
                    .pid = pid,
                    .command = command,
                    .env_type = env_type,
                    .started_at = shared.context.timestamp(),
                    .child = child_copy,
                    .used = true,
                    .cwd = cwd_copy,
                };
                process_count += 1;

                return ToolResult.ok(try std.fmt.allocPrint(allocator,
                    \\{{"started":true,"pid":{d},"detached":true,"env":"{s}","slot":{d}}}
                , .{ pid, @tagName(env_type), s }));
            } else {
                return ToolResult.fail("Process table full");
            }
        } else {
            var timeout_secs: i64 = 300;
            if (timeout) |t| timeout_secs = t;

            const start_time = shared.context.timestamp();
            const result = std.process.run(allocator, shared.context.io(), .{
                .argv = argv[0..argc],
                .cwd = if (cwd != null and env_type == .local) .{ .path = cwd.? } else .inherit,
                .stdout_limit = .limited(MAX_OUTPUT_BYTES),
                .stderr_limit = .limited(MAX_STDERR_BYTES),
            }) catch |err| {
                return ToolResult.fail(std.fmt.allocPrint(allocator, "Failed to spawn process: {}", .{err}) catch "Failed to spawn");
            };
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);

            if (shared.context.timestamp() - start_time > timeout_secs) {
                return ToolResult.fail("Process timed out");
            }

            const exit_code: i32 = switch (result.term) {
                .exited => |code| code,
                .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
                .stopped => |sig| @as(i32, @intCast(@intFromEnum(sig))) + 128,
                else => -1,
            };

            const truncated_stdout = if (result.stdout.len > MAX_OUTPUT_BYTES)
                result.stdout[0..MAX_OUTPUT_BYTES]
            else
                result.stdout;

            return ToolResult.ok(try std.fmt.allocPrint(allocator,
                \\{{"exited":true,"exit_code":{d},"stdout":"{s}","stderr":"{s}","truncated":{}}}
            , .{ exit_code, truncated_stdout, result.stderr, result.stdout.len > MAX_OUTPUT_BYTES }));
        }
    }

    fn listProcesses(_self: *SpawnTool, allocator: std.mem.Allocator) !ToolResult {
        _ = _self;
        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &output);

        try allocating.writer.writeAll("{\"processes\":[");
        var first = true;
        var found_count: usize = 0;

        for (0..MAX_PROCESSES) |i| {
            if (process_table[i].used) {
                if (!first) try allocating.writer.writeAll(",");
                first = false;
                found_count += 1;

                try allocating.writer.print(
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

        try allocating.writer.writeAll("],\"count\":");
        try allocating.writer.print("{}", .{found_count});
        try allocating.writer.writeAll("}");

        output = allocating.toArrayList();
        return ToolResult.ok(try output.toOwnedSlice(allocator));
    }

    fn killProcess(_self: *SpawnTool, allocator: std.mem.Allocator, pid: i32) !ToolResult {
        _ = _self;
        const slot = findByPid(pid);
        if (slot) |s| {
            if (process_table[s].env_type == .docker) {
                const docker_argv = &[_][]const u8{ "docker", "kill", "--signal=KILL", try std.fmt.allocPrint(allocator, "{d}", .{pid}) };
                _ = std.process.spawn(shared.context.io(), .{
                    .argv = docker_argv,
                }) catch {};
            }

            if (std.c.kill(pid, std.c.SIG.KILL) != 0) {
                return ToolResult.fail("Failed to kill process");
            }
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
                const term = c.wait(shared.context.io()) catch |err| {
                    return ToolResult.fail(try std.fmt.allocPrint(allocator, "Failed to wait: {}", .{err}));
                };

                const exit_code: i32 = switch (term) {
                    .exited => |code| code,
                    .signal => |sig| -@as(i32, @intCast(@intFromEnum(sig))),
                    .stopped => |sig| @as(i32, @intCast(@intFromEnum(sig))) + 128,
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

    fn validateSpawnCommand(command: []const u8) ?[]const u8 {
        if (command.len == 0) return "Empty command";

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

        const trimmed = std.mem.trim(u8, command, " \t\n");
        if (std.mem.startsWith(u8, trimmed, "cd ")) return "cd not allowed";
        if (std.mem.startsWith(u8, trimmed, "export ")) return "export not allowed";
        if (std.mem.startsWith(u8, trimmed, "source ")) return "source not allowed";

        return null;
    }

    pub const vtable = root.ToolVTable(@This());
};
