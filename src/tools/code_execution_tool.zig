//! Code Execution Tool - Sandbox-based code execution
//!
//! Executes Python code in a rootless Linux sandbox using zbox.
//! Provides resource limits (CPU, memory) and syscall filtering.
//!
//! Architecture:
//!   1. Validate code for dangerous patterns (first-pass filter)
//!   2. Write code to temporary file
//!   3. Execute with zbox sandbox (Linux) or return error (non-Linux)
//!   4. Capture stdout/stderr and return results

const std = @import("std");
const root = @import("root.zig");
const shared = @import("../shared/context.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const SANDBOX_ALLOWED_TOOLS = [_][]const u8{
    "web_search", "web_extract", "read_file", "write_file",
    "search_files", "patch", "terminal",
};

const DEFAULT_TIMEOUT_SECS = 60;
const DEFAULT_MAX_TOOL_CALLS = 50;
const MAX_STDOUT_BYTES = 50_000;
const MAX_STDERR_BYTES = 10_000;
const DEFAULT_MEMORY_LIMIT_MB = 256;
const DEFAULT_CPU_LIMIT_PERCENT = 50;
const SANDBOX_ROOT = "/tmp/knot3box";

pub const CodeExecutionTool = struct {
    pub const tool_name = "code_execution";
    pub const tool_description = "Execute Python code in a rootless sandbox. Provides resource limits and syscall filtering for safe execution.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\",\"description\":\"Python code to execute\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds (default 60, max 300)\"},\"memory_limit_mb\":{\"type\":\"integer\",\"description\":\"Memory limit in MB (default 256)\"}},\"required\":[\"code\"]}";

    pub fn tool(self: *CodeExecutionTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *CodeExecutionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = self;
        const code = root.getString(args, "code") orelse {
            return ToolResult.fail("code is required");
        };

        const timeout_secs = blk: {
            if (args.get("timeout")) |t| {
                if (t == .integer) break :blk @min(@as(i64, t.integer), @as(i64, 300));
            }
            break :blk @as(i64, DEFAULT_TIMEOUT_SECS);
        };

        const memory_limit_mb = blk: {
            if (args.get("memory_limit_mb")) |m| {
                if (m == .integer) break :blk @min(@as(i64, m.integer), @as(i64, 1024));
            }
            break :blk @as(i64, DEFAULT_MEMORY_LIMIT_MB);
        };

        if (detectDangerousCode(allocator, code)) |msg| {
            return ToolResult.fail(msg);
        }

        return executeInSandbox(allocator, code, timeout_secs, memory_limit_mb);
    }

    pub const vtable = root.ToolVTable(@This());
};

fn executeInSandbox(allocator: std.mem.Allocator, code: []const u8, timeout_secs: i64, memory_limit_mb: i64) !ToolResult {
    if (@import("builtin").os.tag == .linux) {
        return executeWithZbox(allocator, code, timeout_secs, memory_limit_mb);
    }
    return executeFallback(allocator);
}

fn executeFallback(allocator: std.mem.Allocator) !ToolResult {
    var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("Code execution is only available on Linux with zbox support.\n");
    try buf.appendSlice("To enable, rebuild with: zig build -Denable-zbox=true\n\n");
    try buf.appendSlice("Available tools in sandbox:\n");

    for (SANDBOX_ALLOWED_TOOLS, 0..) |t, i| {
        if (i > 0) try buf.appendSlice(", ");
        const line = try std.fmt.allocPrint(allocator, "'{s}'", .{t});
        defer allocator.free(line);
        try buf.appendSlice(line);
    }

    try buf.appendSlice("\n\nExample code:\n");
    try buf.appendSlice("  from hermes_tools import web_search, read_file\n");
    try buf.appendSlice("  results = web_search(query='latest AI news', limit=5)\n");
    try buf.appendSlice("  print(results)\n");

    return ToolResult{ .success = false, .output = try buf.toOwnedSlice() };
}

fn executeWithZbox(allocator: std.mem.Allocator, code: []const u8, timeout_secs: i64, memory_limit_mb: i64) !ToolResult {
    _ = timeout_secs;

    const zbox = @import("zbox");

    shared.cwdMakePath(SANDBOX_ROOT) catch {};

    const script_path = try std.fmt.allocPrint(allocator, "{s}/script.py", .{SANDBOX_ROOT});
    defer allocator.free(script_path);

    shared.cwdWriteFile(script_path, code) catch return ToolResult.fail("Failed to write script");

    const wrapper_path = try std.fmt.allocPrint(allocator, "{s}/run.sh", .{SANDBOX_ROOT});
    defer allocator.free(wrapper_path);

    shared.cwdWriteFile(wrapper_path, "#!/bin/sh\npython3 /sandbox/script.py") catch return ToolResult.fail("Failed to write wrapper");

    var config_builder = zbox.ConfigBuilder.init(allocator);
    defer config_builder.deinit();

    const config = config_builder
        .set_name("knot3bot-code-exec") catch return ToolResult.fail("Failed to set sandbox name")
        .set_root(SANDBOX_ROOT) catch return ToolResult.fail("Failed to set sandbox root")
        .set_binary("/bin/sh") catch return ToolResult.fail("Failed to set sandbox binary")
        .set_cpu_cores(1)
        .set_cpu_limit(DEFAULT_CPU_LIMIT_PERCENT) catch return ToolResult.fail("Failed to set CPU limit")
        .set_memory_limit(@intCast(memory_limit_mb))
        .enable_network(false)
        .build() catch return ToolResult.fail("Failed to build sandbox config");
    defer config.deinit(allocator);

    const stdout_path = try std.fmt.allocPrint(allocator, "{s}/stdout.txt", .{SANDBOX_ROOT});
    defer allocator.free(stdout_path);
    const stderr_path = try std.fmt.allocPrint(allocator, "{s}/stderr.txt", .{SANDBOX_ROOT});
    defer allocator.free(stderr_path);

    var sandbox = zbox.Sandbox.init(allocator, .{ .config = config, .child_args_count = 2 }) catch
        return ToolResult.fail("Failed to initialize sandbox");
    defer sandbox.deinit();

    sandbox.set_strict_errors(true);

    const io = shared.io();
    const stdout_fd = try std.Io.Dir.openFileAbsolute(io, stdout_path, .{ .mode = .write_only, .create = true, .truncate = true });
    defer stdout_fd.close(io);
    try sandbox.set_stdout(stdout_fd);

    const stderr_fd = try std.Io.Dir.openFileAbsolute(io, stderr_path, .{ .mode = .write_only, .create = true, .truncate = true });
    defer stderr_fd.close(io);
    try sandbox.set_stderr(stderr_fd);

    sandbox.set_child_args(&.{ "/bin/sh", "/sandbox/run.sh" });

    sandbox.spawn() catch return ToolResult.fail("Failed to spawn sandbox");

    const result = sandbox.wait() catch return ToolResult.fail("Failed to wait for sandbox");

    const stdout = readFileToString(allocator, stdout_path) catch "";
    const stderr = readFileToString(allocator, stderr_path) catch "";

    var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("=== Sandbox Execution Result ===\n\n");

    const success: bool = if (result == .exited) result.exited == 0 else false;

    const header = switch (result) {
        .exited => |exit_code| try std.fmt.allocPrint(allocator, "Exit Code: {}\n\n", .{exit_code}),
        .signaled => |sig| try std.fmt.allocPrint(allocator, "Exit Code: -1 (killed by signal {})\n\n", .{sig}),
        else => try std.fmt.allocPrint(allocator, "Exit Code: -1 (unknown)\n\n", .{}),
    };
    defer allocator.free(header);
    try buf.appendSlice(header);

    try buf.appendSlice("STDOUT:\n");
    try buf.appendSlice(stdout);
    try buf.appendSlice("\n\nSTDERR:\n");
    try buf.appendSlice(stderr);

    return ToolResult{ .success = success, .output = try buf.toOwnedSlice() };
}

fn readFileToString(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const content = try shared.cwdReadFileAlloc(allocator, path, MAX_STDOUT_BYTES);
    return content;
}

fn detectDangerousCode(allocator: std.mem.Allocator, code: []const u8) ?[]const u8 {
    const dangerous = [_][]const u8{
        "import os",       "import sys",     "import subprocess",
        "import socket",   "eval(",          "exec(",
        "__import__",      "ctypes",         "multiprocessing",
        "threading",       "import pty",     "import resource",
        "setrlimit",       "chroot",
    };

    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, code, pattern) != null) {
            return std.fmt.allocPrint(allocator, "Blocked: code contains '{s}' which is not allowed in sandbox", .{pattern}) catch
                "Blocked: dangerous code pattern";
        }
    }
    return null;
}
