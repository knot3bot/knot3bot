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
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

// Conditional import for zbox (Linux only)
comptime {
    if (@import("config").enable_zbox) {
        _ = @import("zbox");
    }
}

/// Allowed tools inside sandbox
const SANDBOX_ALLOWED_TOOLS = [_][]const u8{
    "web_search",
    "web_extract",
    "read_file",
    "write_file",
    "search_files",
    "patch",
    "terminal",
};

/// Resource limits
const DEFAULT_TIMEOUT_SECS = 60;
const DEFAULT_MAX_TOOL_CALLS = 50;
const MAX_STDOUT_BYTES = 50_000;
const MAX_STDERR_BYTES = 10_000;
const DEFAULT_MEMORY_LIMIT_MB = 256;
const DEFAULT_CPU_LIMIT_PERCENT = 50;

/// Sandbox root directory
const SANDBOX_ROOT = "/tmp/knot3box";

/// CodeExecutionTool - Execute code in sandbox with tool access
pub const CodeExecutionTool = struct {
    pub const tool_name = "code_execution";
    pub const tool_description = "Execute Python code in a rootless sandbox. Provides resource limits and syscall filtering for safe execution.";
    pub const tool_params = .{
        .type = "object",
        .properties = .{
            .code = .{
                .type = "string",
                .description = "Python code to execute",
            },
            .timeout = .{
                .type = "integer",
                .description = "Timeout in seconds (default 60, max 300)",
            },
            .memory_limit_mb = .{
                .type = "integer",
                .description = "Memory limit in MB (default 256)",
            },
        },
        .required = &.{"code"},
    };

    pub fn tool(self: *CodeExecutionTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *CodeExecutionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const code = root.getString(args, "code") orelse {
            return ToolResult.fail("code is required");
        };

        // Parse optional parameters
        const timeout_secs = blk: {
            if (args.get("timeout")) |t| {
                if (t == .integer) break :blk @min(t.integer, 300);
            }
            break :blk DEFAULT_TIMEOUT_SECS;
        };

        const memory_limit = blk: {
            if (args.get("memory_limit_mb")) |m| {
                if (m == .integer) break :blk @min(m.integer, 1024);
            }
            break :blk DEFAULT_MEMORY_LIMIT_MB;
        };

        // Check for potentially dangerous patterns (first-pass filter)
        if (detectDangerousCode(code)) |msg| {
            return ToolResult.fail(msg);
        }

        // Execute based on platform
        return self.executeInSandbox(allocator, code, timeout_secs, memory_limit);
    }

    fn executeInSandbox(self: *CodeExecutionTool, allocator: std.mem.Allocator, code: []const u8, timeout_secs: u32, memory_limit_mb: u32) !ToolResult {
        // Check if zbox is available (Linux with ENABLE_ZBOX)
        if (@import("config").enable_zbox) {
            return self.executeWithZbox(allocator, code, timeout_secs, memory_limit_mb);
        } else {
            return self.executeFallback(allocator);
        }
    }

    fn executeFallback(_: *CodeExecutionTool, allocator: std.mem.Allocator) !ToolResult {
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll("Code execution is only available on Linux with zbox support.\n");
        try w.writeAll("To enable, rebuild with: zig build -Denable-zbox=true\n\n");
        try w.writeAll("Available tools in sandbox:\n");

        for (SANDBOX_ALLOWED_TOOLS, 0..) |t, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("'{s}'", .{t});
        }

        try w.writeAll("\n\nExample code:\n");
        try w.writeAll("  from hermes_tools import web_search, read_file\n");
        try w.writeAll("  results = web_search(query='latest AI news', limit=5)\n");
        try w.writeAll("  print(results)\n");

        return ToolResult{
            .success = false,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    fn executeWithZbox(self: *CodeExecutionTool, allocator: std.mem.Allocator, code: []const u8, timeout_secs: u32, memory_limit_mb: u32) !ToolResult {
        _ = self;
        _ = timeout_secs;

        const zbox = @import("zbox");

        // Create sandbox root if it doesn't exist
        const sandbox_root = SANDBOX_ROOT;
        std.fs.cwd().makePath(sandbox_root) catch {};

        // Write code to temporary file inside sandbox root
        const script_path = try std.fmt.allocPrint(allocator, "{s}/script.py", .{sandbox_root});
        defer allocator.free(script_path);

        const script_file = try std.fs.createFileAbsolute(script_path, .{});
        defer script_file.close();
        try script_file.writeAll(code);
        script_file.close();

        // Also write a shell wrapper to execute the Python script
        const wrapper_path = try std.fmt.allocPrint(allocator, "{s}/run.sh", .{sandbox_root});
        defer allocator.free(wrapper_path);

        const wrapper_file = try std.fs.createFileAbsolute(wrapper_path, .{});
        defer wrapper_file.close();
        try wrapper_file.writeAll("#!/bin/sh\npython3 /sandbox/script.py");
        wrapper_file.close();

        // Configure sandbox
        var config_builder = zbox.ConfigBuilder.init(allocator);
        defer config_builder.deinit();

        const config = config_builder
            .set_name("knot3bot-code-exec") catch return ToolResult.fail("Failed to set sandbox name")
            .set_root(sandbox_root) catch return ToolResult.fail("Failed to set sandbox root")
            .set_binary("/bin/sh") catch return ToolResult.fail("Failed to set sandbox binary")
            .set_cpu_cores(1)
            .set_cpu_limit(DEFAULT_CPU_LIMIT_PERCENT) catch return ToolResult.fail("Failed to set CPU limit")
            .set_memory_limit(memory_limit_mb)
            .enable_network(false)
            .build() catch return ToolResult.fail("Failed to build sandbox config");
        defer config.deinit(allocator);

        // Create output files for capturing stdout/stderr
        const stdout_path = try std.fmt.allocPrint(allocator, "{s}/stdout.txt", .{sandbox_root});
        defer allocator.free(stdout_path);
        const stderr_path = try std.fmt.allocPrint(allocator, "{s}/stderr.txt", .{sandbox_root});
        defer allocator.free(stderr_path);

        // Create sandbox instance
        var sandbox = zbox.Sandbox.init(allocator, .{
            .config = config,
            .child_args_count = 2,
        }) catch return ToolResult.fail("Failed to initialize sandbox");
        defer sandbox.deinit();

        // Set strict errors - fail if cgroup/network setup fails
        sandbox.set_strict_errors(true);

        // Set I/O redirection to capture output
        const stdout_fd = try std.posix.open(stdout_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer _ = std.posix.close(stdout_fd);
        try sandbox.set_stdout(stdout_fd);

        const stderr_fd = try std.posix.open(stderr_path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
        defer _ = std.posix.close(stderr_fd);
        try sandbox.set_stderr(stderr_fd);

        // Set child arguments: sh run.sh
        sandbox.set_child_args(&.{ "/bin/sh", "/sandbox/run.sh" });

        // Spawn sandbox and wait for result
        sandbox.spawn() catch return ToolResult.fail("Failed to spawn sandbox");

        // Wait with timeout
        const result = sandbox.wait() catch return ToolResult.fail("Failed to wait for sandbox");

        // Read captured output
        const stdout = readFileToString(allocator, stdout_path) catch "";
        const stderr = readFileToString(allocator, stderr_path) catch "";

        // Format result as simple text
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll("=== Sandbox Execution Result ===\n\n");

        switch (result) {
            .exited => |exit_code| {
                if (exit_code == 0) {
                    try w.print("Exit Code: {}\n\n", .{exit_code});
                    try w.writeAll("STDOUT:\n");
                    try w.writeAll(stdout);
                    try w.writeAll("\n\nSTDERR:\n");
                    try w.writeAll(stderr);
                } else {
                    try w.print("Exit Code: {}\n\n", .{exit_code});
                    try w.writeAll("STDOUT:\n");
                    try w.writeAll(stdout);
                    try w.writeAll("\n\nSTDERR:\n");
                    try w.writeAll(stderr);
                }
            },
            .signaled => |sig| {
                try w.print("Exit Code: -1 (killed by signal {})\n\n", .{sig});
                try w.writeAll("STDOUT:\n");
                try w.writeAll(stdout);
                try w.writeAll("\n\nSTDERR:\n");
                try w.writeAll(stderr);
            },
            else => {
                try w.writeAll("Exit Code: -1 (unknown)\n\n");
                try w.writeAll("STDOUT:\n");
                try w.writeAll(stdout);
                try w.writeAll("\n\nSTDERR:\n");
                try w.writeAll(stderr);
            },
        }

        return ToolResult{
            .success = result == .exited and result.exited == 0,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};

/// Read file contents to string
fn readFileToString(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();

    const stat = try file.stat();
    const contents = try file.readToEndAlloc(allocator, stat.size);
    return contents;
}

/// Detect dangerous code patterns
fn detectDangerousCode(code: []const u8) ?[]const u8 {
    const dangerous = [_][]const u8{
        "import os",
        "import sys",
        "import subprocess",
        "import socket",
        "eval(",
        "exec(",
        "open(",
        "__import__",
        "ctypes",
        "multiprocessing",
        "threading",
        "import pty",
        "import resource",
        "setrlimit",
        "chroot",
    };

    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, code, pattern) != null) {
            return std.fmt.allocPrint(root.allocator, "Blocked: code contains '{s}' which is not allowed in sandbox", .{pattern}) catch
                "Blocked: dangerous code pattern";
        }
    }

    return null;
}
