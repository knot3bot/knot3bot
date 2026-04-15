//! HTTP Request tool - Make HTTP requests to any endpoint
//!
//! Supports GET, POST, PUT, DELETE methods with custom headers

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const validation = @import("../validation.zig");

pub const HttpRequestTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "http_request";
    pub const tool_description = "Make HTTP requests to any URL with custom method, headers, and body";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"The URL to request\"},\"method\":{\"type\":\"string\",\"description\":\"HTTP method: GET, POST, PUT, DELETE, PATCH\"},\"headers\":{\"type\":\"string\",\"description\":\"Headers as comma-separated 'name:value' pairs\"},\"body\":{\"type\":\"string\",\"description\":\"Request body (for POST/PUT)\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds (default: 30)\"}},\"required\":[\"url\"]}";

    pub fn tool(self: *HttpRequestTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_self: *HttpRequestTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = _self;
        const url = getString(args, "url") orelse return ToolResult.fail("url required");

        // Security: validate URL to prevent SSRF attacks
        validation.validateUrl(url) catch {
            return ToolResult.fail("Invalid or blocked URL (SSRF protection)");
        };

        const method = getString(args, "method") orelse "GET";
        const headers_str = getString(args, "headers");
        const body = getString(args, "body");
        const timeout_str = getString(args, "timeout");
        const timeout: u32 = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30 else 30;

        // Build curl command
        var argv: std.ArrayList([]const u8) = .empty;
        errdefer argv.deinit(allocator);

        try argv.append(allocator, "curl");
        try argv.append(allocator, "-s");
        try argv.append(allocator, "-X");
        try argv.append(allocator, method);
        try argv.append(allocator, "-w");
        try argv.append(allocator, "\\n%{http_code}");
        try argv.append(allocator, "--max-time");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{timeout}));

        // Add headers (comma-separated "name:value" pairs)
        if (headers_str) |h| {
            var parts = std.mem.splitSequence(u8, h, ",");
            while (parts.next()) |pair| {
                const trimmed = std.mem.trim(u8, pair, " \t");
                if (trimmed.len > 0) {
                    if (std.mem.indexOf(u8, trimmed, ":")) |colon_idx| {
                        const name = trimmed[0..colon_idx];
                        const value = trimmed[colon_idx + 1 ..];
                        try argv.append(allocator, "-H");
                        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{s}: {s}", .{ name, std.mem.trim(u8, value, " \t") }));
                    }
                }
            }
        }

        // Add body for POST/PUT
        if (body != null and (std.mem.eql(u8, method, "POST") or std.mem.eql(u8, method, "PUT") or std.mem.eql(u8, method, "PATCH"))) {
            try argv.append(allocator, "-d");
            try argv.append(allocator, body.?);
        }

        try argv.append(allocator, url);

        var child = std.process.Child.init(try argv.toOwnedSlice(allocator), allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const max_response_size = 8 * 1024 * 1024; // 8MB
        const stdout = child.stdout.?.readToEndAlloc(allocator, max_response_size) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return ToolResult.fail("Failed to read response");
        };
        defer allocator.free(stdout);

        const term = child.wait() catch {
            return ToolResult.fail("Failed to wait for curl");
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    // Parse response and status code
                    const last_newline = std.mem.lastIndexOf(u8, stdout, "\n");
                    if (last_newline) |idx| {
                        const status_str = stdout[idx + 1 ..];
                        const response_body = stdout[0..idx];
                        const status_code = std.fmt.parseInt(u16, status_str, 10) catch 200;
                        return ToolResult.ok(try std.fmt.allocPrint(allocator,
                            \\{{"status":{d},"body":"{s}"}}
                        , .{ status_code, response_body }));
                    }
                    return ToolResult.ok(stdout);
                } else {
                    return ToolResult.fail(try std.fmt.allocPrint(allocator, "HTTP request failed with code {d}", .{code}));
                }
            },
            else => return ToolResult.fail("HTTP request failed"),
        }
    }

    pub const vtable = root.ToolVTable(@This());
};
