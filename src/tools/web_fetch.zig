//! Web Fetch tool - Simple web page/content fetcher
//!
//! Fetches content from URLs with automatic content-type handling

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const validateUrl = @import("../validation.zig").validateUrl;
pub const WebFetchTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "web_fetch";
    pub const tool_description = "Fetch web page content from a URL (simplified HTTP GET)";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"The URL to fetch\"},\"timeout\":{\"type\":\"integer\",\"description\":\"Timeout in seconds (default: 30)\"},\"max_size\":{\"type\":\"integer\",\"description\":\"Maximum response size in bytes (default: 1048576)\"}},\"required\":[\"url\"]}";

    pub fn tool(self: *WebFetchTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_self: *WebFetchTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        _ = _self;
        const url = getString(args, "url") orelse return ToolResult.fail("url required");

        // Security: validate URL to prevent SSRF attacks
        validateUrl(url) catch |err| {
            const err_msg = switch (err) {
                error.InvalidUrl => "Invalid URL (null bytes not allowed)",
                error.BlockedUrlScheme => "file:// scheme is blocked",
                error.BlockedHost => "localhost/private IPs are blocked",
                else => "Invalid URL",
            };
            return ToolResult.fail(err_msg);
        };
        const timeout_str = getString(args, "timeout");
        const max_size_str = getString(args, "max_size");

        const timeout: u32 = if (timeout_str) |t| std.fmt.parseInt(u32, t, 10) catch 30 else 30;
        const max_size: usize = if (max_size_str) |s| std.fmt.parseInt(usize, s, 10) catch 1048576 else 1048576;
        // Simple curl-based fetch
        const argv = &[_][]const u8{
            "curl",
            "-s",
            "--max-time",
            try std.fmt.allocPrint(allocator, "{d}", .{timeout}),
            "-L", // Follow redirects
            "-A",
            "knot3bot/1.0",
            url,
        };

        var child = std.process.Child.init(argv, allocator);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;

        try child.spawn();

        const stdout = child.stdout.?.readToEndAlloc(allocator, max_size) catch {
            _ = child.kill() catch {};
            _ = child.wait() catch {};
            return ToolResult.fail("Failed to read response (too large or network error)");
        };
        defer allocator.free(stdout);

        const term = child.wait() catch {
            return ToolResult.fail("Failed to wait for curl");
        };

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    return ToolResult.ok(stdout);
                } else {
                    return ToolResult.fail(try std.fmt.allocPrint(allocator, "Fetch failed with code {d}", .{code}));
                }
            },
            else => return ToolResult.fail("Fetch failed"),
        }
    }

    pub const vtable = root.ToolVTable(@This());
};
