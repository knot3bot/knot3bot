//! Code Execution Tool - Sandbox-based code execution
//!
//! Executes Python code safely. A zbox-based rootless Linux sandbox was
//! planned but never shipped; see executeInSandbox.
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
    "web_search",   "web_extract", "read_file", "write_file",
    "search_files", "patch",       "terminal",
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
    // The zbox sandbox was never shipped (its vendored source was a dangling
    // gitlink); code execution currently falls back to a guided refusal.
    _ = code;
    _ = timeout_secs;
    _ = memory_limit_mb;
    return executeFallback(allocator);
}

fn executeFallback(allocator: std.mem.Allocator) !ToolResult {
    var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
    defer buf.deinit();

    try buf.appendSlice("Code execution sandbox is not available in this build.\n\n");
    try buf.appendSlice("Sandboxed tools that would be available:\n");

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

fn readFileToString(allocator: std.mem.Allocator, path: []const u8) ![]const u8 {
    const content = try shared.cwdReadFileAlloc(allocator, path, MAX_STDOUT_BYTES);
    return content;
}

fn detectDangerousCode(allocator: std.mem.Allocator, code: []const u8) ?[]const u8 {
    const dangerous = [_][]const u8{
        "import os",     "import sys", "import subprocess",
        "import socket", "eval(",      "exec(",
        "__import__",    "ctypes",     "multiprocessing",
        "threading",     "import pty", "import resource",
        "setrlimit",     "chroot",
    };

    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, code, pattern) != null) {
            return std.fmt.allocPrint(allocator, "Blocked: code contains '{s}' which is not allowed in sandbox", .{pattern}) catch
                "Blocked: dangerous code pattern";
        }
    }
    return null;
}
