//! MCP (Model Context Protocol) Tool
//!
//! Connects to external MCP servers via stdio or HTTP/StreamableHTTP transport,
//! discovers their tools, and registers them into the tool registry.
//!
//! Configuration is read from config.yaml under the ``mcp_servers`` key.
//!
//! This is a simplified implementation. Full MCP support requires:
//! - Async event loop infrastructure
//! - MCP SDK integration (@cImport or native Zig MCP client)
//! - Thread-safe server session management
//! - Sampling callback support for server-initiated LLM requests

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// MCP Server configuration
pub const MCPServerConfig = struct {
    name: []const u8,
    command: ?[]const u8 = null,
    args: ?[]const []const u8 = null,
    env: ?std.json.ObjectMap = null,
    url: ?[]const u8 = null,
    headers: ?std.json.ObjectMap = null,
    timeout: u32 = 120,
    connect_timeout: u32 = 60,
};

/// MCP Tool - Provides access to MCP server tools
pub const MCPTool = struct {
    pub const tool_name = "mcp";
    pub const tool_description = "Call a tool from a connected MCP (Model Context Protocol) server. Servers must be configured in config.yaml under mcp_servers.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\",\"description\":\"MCP server name from config\"},\"tool\":{\"type\":\"string\",\"description\":\"Tool name to call\"},\"arguments\":{\"type\":\"object\",\"description\":\"Tool arguments as key-value pairs\"}},\"required\":[\"server\",\"tool\"]}";

    /// List available MCP servers (placeholder - would need runtime state)
    pub fn listServers() []const u8 {
        return "MCP servers must be configured in config.yaml. This is a placeholder - full MCP support requires async infrastructure.";
    }

    pub fn tool(self: *MCPTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *MCPTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const server = root.getString(args, "server") orelse {
            return ToolResult.fail("server is required");
        };
        const mcp_tool_name = root.getString(args, "tool") orelse {
            return ToolResult.fail("tool is required");
        };

        // Get optional arguments
        var args_json: []const u8 = "{}";
        if (args.get("arguments")) |args_val| {
            if (args_val == .object) {
                // Serialize arguments object to JSON string
                var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
                defer buf.deinit();
                try std.json.stringify(buf.writer(), args_val.object.?, .{});
                args_json = try buf.toOwnedSlice(allocator);
            }
        }

        // Build response indicating MCP requires async infrastructure
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.print(
            \\{{"error":"MCP tool calls require async infrastructure. 
            \\Server '{s}' tool '{s}' called with args: {s}
            \\Full MCP support requires: async event loop, MCP SDK integration, and configured mcp_servers in config.yaml."}}
        , .{ server, mcp_tool_name, args_json });

        return ToolResult{
            .success = false,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};

/// MCP List Servers Tool - List configured MCP servers
pub const MCPListServersTool = struct {
    pub const tool_name = "mcp_list_servers";
    pub const tool_description = "List all configured MCP servers and their connection status.";
    pub const tool_params = "{}";

    pub fn tool(self: *MCPListServersTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *MCPListServersTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll(
            \\{"servers":[],"message":"MCP servers must be configured in config.yaml under mcp_servers. 
            \\Example configuration:
            \\mcp_servers:
            \\  filesystem:
            \\    command: npx
            \\    args: [-y, @modelcontextprotocol/server-filesystem, /tmp]
            \\  github:
            \\    command: npx  
            \\    args: [-y, @modelcontextprotocol/server-github]
            \\    env:
            \\      GITHUB_PERSONAL_ACCESS_TOKEN: your_token
            \\
            \\Full MCP support requires async infrastructure."}
        );

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
