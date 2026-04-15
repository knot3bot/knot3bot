//! Code Execution Tool - Programmatic Tool Calling (PTC)
//!
//! Lets the LLM write a Python script that calls Hermes tools via RPC,
//! collapsing multi-step tool chains into a single inference turn.
//!
//! Architecture:
//!   **Local backend (UDS):**
//!   1. Parent generates a hermes_tools.py stub module with UDS RPC functions
//!   2. Parent opens a Unix domain socket and starts an RPC listener thread
//!   3. Parent spawns a child process that runs the LLM's script
//!   4. Tool calls travel over the UDS back to the parent for dispatch
//!
//!   **Remote backends (file-based RPC):**
//!   1. Parent generates hermes_tools.py with file-based RPC stubs
//!   2. Parent ships both files to the remote environment
//!   3. Script runs inside the terminal backend (Docker/SSH/Modal/etc.)
//!   4. Tool calls are written as request files; a polling thread reads them
//!
//! This is a simplified placeholder. Full implementation requires:
//!   - Unix domain socket (UDS) support
//!   - Threading for RPC listener
//!   - Subprocess management
//!   - File-based RPC for remote backends
//!   - Resource limit enforcement

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

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
const DEFAULT_TIMEOUT = 300;
const DEFAULT_MAX_TOOL_CALLS = 50;
const MAX_STDOUT_BYTES = 50_000;
const MAX_STDERR_BYTES = 10_000;

/// CodeExecutionTool - Execute code in sandbox with tool access
pub const CodeExecutionTool = struct {
    pub const tool_name = "code_execution";
    pub const tool_description = "Execute a Python script that can call Hermes tools via RPC. The script runs in a sandbox with access to allowed tools.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"code\":{\"type\":\"string\",\"description\":\"Python code to execute. Can import hermes_tools for tool access.\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds (default 300)\"}},\"required\":[\"code\"]}";

    pub fn tool(self: *CodeExecutionTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *CodeExecutionTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const code = root.getString(args, "code") orelse {
            return ToolResult.fail("code is required");
        };

        const timeout = args.get("timeout") orelse std.json.Value{ .integer = DEFAULT_TIMEOUT };
        const timeout_secs = if (timeout == .integer) timeout.integer else DEFAULT_TIMEOUT;

        // Check for potentially dangerous patterns
        if (detectDangerousCode(code)) |msg| {
            return ToolResult.fail(msg);
        }

        // Build response explaining sandbox requirements
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll(
            \\{"error":"Code execution requires async infrastructure and sandbox environment.
            \\The code you provided would run in a hermes_tools.py RPC sandbox.
            \\
            \\Available tools in sandbox:
        );

        for (SANDBOX_ALLOWED_TOOLS, 0..) |t, i| {
            if (i > 0) try w.writeAll(", ");
            try w.print("'{s}'", .{t});
        }

        try w.print(
            \\
            \\Example code:
            \\  from hermes_tools import web_search, read_file
            \\  results = web_search(query='latest AI news', limit=5)
            \\  print(results)
            \\
            \\Timeout: {d}s
            \\Max tool calls: {d}
            \\
            \\Full code execution requires: Unix domain sockets, threading, subprocess management."}}
        , .{ timeout_secs, DEFAULT_MAX_TOOL_CALLS });

        return ToolResult{
            .success = false,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};

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
    };

    for (dangerous) |pattern| {
        if (std.mem.indexOf(u8, code, pattern) != null) {
            return std.fmt.allocPrint(root.allocator,
                "Blocked: code contains '{s}' which is not allowed in sandbox", .{pattern}) catch
                "Blocked: dangerous code pattern";
        }
    }

    return null;
}
