//! MCP (Model Context Protocol) client tool — stdio transport.
//!
//! Talks to external MCP servers configured in the knot3bot config file
//! (`mcp_servers` array) over JSON-RPC on the server's stdin/stdout.
//!
//! Session lifecycle: each tool invocation spawns the server process,
//! performs the MCP initialize handshake, executes the requested operation
//! (list tools / call tool) and shuts the server down. Stateful long-lived
//! sessions would need an event loop; the per-call lifecycle keeps the
//! implementation synchronous and robust.
//!
//! Config example (knot3bot.json):
//! ```json
//! {
//!   "mcp_servers": [
//!     { "name": "filesystem", "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "/tmp"] }
//!   ]
//! }
//! ```

const std = @import("std");
const shared = @import("../shared/root.zig");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// MCP protocol version this client speaks.
const protocol_version = "2024-11-05";
/// Guard rails for reading server output.
const max_message_bytes = 1024 * 1024;
const max_messages = 10_000;

/// MCP Server configuration (from the `mcp_servers` config array).
/// All strings are owned by the caller-provided allocator.
pub const MCPServerConfig = struct {
    name: []const u8,
    command: []const u8 = "",
    args: []const []const u8 = &.{},
    url: ?[]const u8 = null,
};

fn fileExists(path: []const u8) bool {
    const io = shared.context.io();
    _ = shared.context.cwd().statFile(io, path, .{}) catch return false;
    return true;
}

/// Locate the knot3bot config file (same resolution as config.Config).
/// Returned path is owned by `allocator`.
fn findConfigPath(allocator: std.mem.Allocator) ?[]const u8 {
    if (shared.context.getenv("KNOT3BOT_CONFIG")) |path| {
        if (path.len > 0) return allocator.dupe(u8, path) catch null;
    }
    if (shared.context.getenv("HOME")) |home| {
        const joined = std.fs.path.join(allocator, &.{ home, ".knot3bot", "config.json" }) catch return null;
        defer allocator.free(joined);
        if (fileExists(joined)) return allocator.dupe(u8, joined) catch null;
    }
    if (fileExists("knot3bot.json")) return allocator.dupe(u8, "knot3bot.json") catch null;
    return null;
}

/// Parse the `mcp_servers` array from a config JSON file.
/// Returned configs (and all their strings) are owned by `allocator`.
pub fn loadServerConfigsFrom(allocator: std.mem.Allocator, path: []const u8) ![]MCPServerConfig {
    const io = shared.context.io();
    const contents = try shared.context.cwd().readFileAlloc(io, path, allocator, .limited(4 * 1024 * 1024));
    defer allocator.free(contents);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
    defer parsed.deinit();

    var out: std.ArrayList(MCPServerConfig) = .empty;
    errdefer {
        for (out.items) |cfg| {
            allocator.free(cfg.name);
            allocator.free(cfg.command);
            if (cfg.url) |u| allocator.free(u);
            for (cfg.args) |a| allocator.free(a);
            allocator.free(cfg.args);
        }
        out.deinit(allocator);
    }

    const servers_val = parsed.value.object.get("mcp_servers") orelse return out.toOwnedSlice(allocator);
    if (servers_val != .array) return error.InvalidConfig;
    for (servers_val.array.items) |item| {
        if (item != .object) return error.InvalidConfig;
        const obj = item.object;
        const name_val = obj.get("name") orelse return error.InvalidConfig;
        if (name_val != .string) return error.InvalidConfig;

        var cfg = MCPServerConfig{ .name = try allocator.dupe(u8, name_val.string) };
        errdefer allocator.free(cfg.name);
        if (obj.get("command")) |cmd| {
            if (cmd == .string) cfg.command = try allocator.dupe(u8, cmd.string);
        }
        if (obj.get("url")) |u| {
            if (u == .string) cfg.url = try allocator.dupe(u8, u.string);
        }
        if (obj.get("args")) |args_val| {
            if (args_val == .array) {
                var args: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (args.items) |a| allocator.free(a);
                    args.deinit(allocator);
                }
                for (args_val.array.items) |a| {
                    if (a == .string) try args.append(allocator, try allocator.dupe(u8, a.string));
                }
                cfg.args = try args.toOwnedSlice(allocator);
            }
        }
        try out.append(allocator, cfg);
    }
    return out.toOwnedSlice(allocator);
}

/// Load MCP server configs from the default config location.
/// Returned configs are owned by `allocator`.
pub fn loadServerConfigs(allocator: std.mem.Allocator) ![]MCPServerConfig {
    const path = findConfigPath(allocator) orelse return error.NoConfigFile;
    defer allocator.free(path);
    return loadServerConfigsFrom(allocator, path);
}

/// A live JSON-RPC session with an MCP stdio server.
const MCPSession = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    next_id: u64 = 1,

    fn spawn(allocator: std.mem.Allocator, cfg: MCPServerConfig) !MCPSession {
        const io = shared.context.io();
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(allocator);
        try argv.append(allocator, cfg.command);
        try argv.appendSlice(allocator, cfg.args);

        const child = try std.process.spawn(io, .{
            .argv = argv.items,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        return .{ .allocator = allocator, .child = child };
    }

    fn send(self: *MCPSession, value: std.json.Value) !void {
        const io = shared.context.io();
        const line = try std.json.Stringify.valueAlloc(self.allocator, value, .{});
        defer self.allocator.free(line);
        const stdin_file = self.child.stdin orelse return error.WriteFailed;
        try stdin_file.writeStreamingAll(io, line);
        try stdin_file.writeStreamingAll(io, "\n");
    }

    fn notify(self: *MCPSession, method: []const u8) !void {
        var map: std.json.ObjectMap = .empty;
        defer map.deinit(self.allocator);
        try map.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try map.put(self.allocator, "method", .{ .string = method });
        try self.send(.{ .object = map });
    }

    /// Send a JSON-RPC request and read lines until the matching response
    /// arrives (server notifications are skipped). Returns the `result`
    /// member serialized as fresh JSON text owned by `allocator`.
    fn request(self: *MCPSession, method: []const u8, params: ?std.json.Value) ![]const u8 {
        const io = shared.context.io();
        const id = self.next_id;
        self.next_id += 1;

        var map: std.json.ObjectMap = .empty;
        defer map.deinit(self.allocator);
        try map.put(self.allocator, "jsonrpc", .{ .string = "2.0" });
        try map.put(self.allocator, "id", .{ .integer = @intCast(id) });
        try map.put(self.allocator, "method", .{ .string = method });
        if (params) |p| try map.put(self.allocator, "params", p);
        try self.send(.{ .object = map });

        const stdout_file = self.child.stdout orelse return error.ReadFailed;
        var buffer: [8192]u8 = undefined;
        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);

        var messages_seen: usize = 0;
        while (messages_seen < max_messages) : (messages_seen += 1) {
            const bytes_read = stdout_file.readStreaming(io, &.{&buffer}) catch return error.ReadFailed;
            if (bytes_read == 0) return error.ProtocolError;
            for (buffer[0..bytes_read]) |byte| {
                if (byte != '\n') {
                    if (line_buf.items.len < max_message_bytes) try line_buf.append(self.allocator, byte);
                    continue;
                }
                if (line_buf.items.len == 0) continue;
                defer line_buf.clearRetainingCapacity();

                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, line_buf.items, .{}) catch continue;
                defer parsed.deinit();
                if (parsed.value != .object) continue;
                const obj = parsed.value.object;
                const resp_id = obj.get("id") orelse continue; // notification
                if (resp_id != .integer or resp_id.integer != @as(i64, @intCast(id))) continue;

                if (obj.get("error")) |err_val| {
                    if (err_val == .object) {
                        if (err_val.object.get("message")) |m| {
                            if (m == .string) std.log.warn("MCP server error: {s}", .{m.string});
                        }
                    }
                    return error.ServerError;
                }
                const result = obj.get("result") orelse return error.ProtocolError;
                // Copy the result out of `parsed`'s lifetime as text.
                return std.json.Stringify.valueAlloc(self.allocator, result, .{});
            }
        }
        return error.ProtocolError;
    }

    fn initialize(self: *MCPSession) !void {
        var client_info: std.json.ObjectMap = .empty;
        defer client_info.deinit(self.allocator);
        try client_info.put(self.allocator, "name", .{ .string = "knot3bot" });
        try client_info.put(self.allocator, "version", .{ .string = "0.4.1" });
        var capabilities: std.json.ObjectMap = .empty;
        defer capabilities.deinit(self.allocator);
        var params: std.json.ObjectMap = .empty;
        defer params.deinit(self.allocator);
        try params.put(self.allocator, "protocolVersion", .{ .string = protocol_version });
        try params.put(self.allocator, "capabilities", .{ .object = capabilities });
        try params.put(self.allocator, "clientInfo", .{ .object = client_info });
        const result = try self.request("initialize", .{ .object = params });
        self.allocator.free(result);
        try self.notify("notifications/initialized");
    }

    fn shutdown(self: *MCPSession) void {
        const io = shared.context.io();
        if (self.child.stdin) |f| {
            f.close(io);
            self.child.stdin = null;
        }
        _ = self.child.wait(io) catch {};
        if (self.child.stdout) |f| {
            f.close(io);
            self.child.stdout = null;
        }
    }
};

fn extractTextContent(allocator: std.mem.Allocator, result: std.json.Value) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var is_error = false;
    if (result == .object) {
        if (result.object.get("isError")) |is_err| {
            if (is_err == .bool and is_err.bool) is_error = true;
        }
        if (result.object.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |block| {
                    if (block != .object) continue;
                    const btype = block.object.get("type") orelse continue;
                    if (btype != .string or !std.mem.eql(u8, btype.string, "text")) continue;
                    const text = block.object.get("text") orelse continue;
                    if (text == .string) try out.appendSlice(allocator, text.string);
                }
            }
        }
    }
    if (is_error) {
        var prefixed: std.ArrayList(u8) = .empty;
        try prefixed.appendSlice(allocator, "[MCP tool error] ");
        try prefixed.appendSlice(allocator, out.items);
        out.deinit(allocator);
        return prefixed.toOwnedSlice(allocator);
    }
    return out.toOwnedSlice(allocator);
}

/// Perform `tools/list` on a server. Returns the raw JSON array of tool
/// descriptors, owned by `allocator`.
pub fn listTools(allocator: std.mem.Allocator, cfg: MCPServerConfig) ![]const u8 {
    if (cfg.url != null) return error.TransportUnsupported;
    var session = try MCPSession.spawn(allocator, cfg);
    defer session.shutdown();
    try session.initialize();
    const result = try session.request("tools/list", null);
    defer allocator.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.ProtocolError;
    const tools = parsed.value.object.get("tools") orelse return error.ProtocolError;
    return std.json.Stringify.valueAlloc(allocator, tools, .{});
}

/// Perform `tools/call` on a server. Returns the concatenated text content,
/// owned by `allocator`. `arguments_json` must be a JSON object (may be empty).
pub fn callTool(allocator: std.mem.Allocator, cfg: MCPServerConfig, tool_name: []const u8, arguments_json: []const u8) ![]const u8 {
    if (cfg.url != null) return error.TransportUnsupported;

    var empty_map: std.json.ObjectMap = .empty;
    defer empty_map.deinit(allocator);
    var arguments: std.json.Value = .{ .object = empty_map };
    var parsed_args: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed_args) |p| p.deinit();
    if (arguments_json.len > 0) {
        parsed_args = try std.json.parseFromSlice(std.json.Value, allocator, arguments_json, .{});
        arguments = parsed_args.?.value;
        if (arguments != .object) return error.InvalidArguments;
    }

    var session = try MCPSession.spawn(allocator, cfg);
    defer session.shutdown();
    try session.initialize();

    var params: std.json.ObjectMap = .empty;
    defer params.deinit(allocator);
    try params.put(allocator, "name", .{ .string = tool_name });
    try params.put(allocator, "arguments", arguments);
    const result = try session.request("tools/call", .{ .object = params });
    defer allocator.free(result);

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    return extractTextContent(allocator, parsed.value);
}

// ── Tool wrappers ───────────────────────────────────────────────────────────

/// MCP Tool — call a tool on a configured MCP server, or list its tools.
pub const MCPTool = struct {
    pub const tool_name = "mcp";
    pub const tool_description = "Interact with a configured MCP (Model Context Protocol) server: call one of its tools, or list the tools it exposes. Servers are configured in the knot3bot config file under \"mcp_servers\" (stdio transport).";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"server\":{\"type\":\"string\",\"description\":\"MCP server name from config\"},\"action\":{\"type\":\"string\",\"enum\":[\"list_tools\",\"call\"],\"description\":\"Operation (default: call when tool is given, otherwise list_tools)\"},\"tool\":{\"type\":\"string\",\"description\":\"Tool name to call\"},\"arguments\":{\"type\":\"object\",\"description\":\"Tool arguments as key-value pairs\"}},\"required\":[\"server\"]}";

    pub fn tool(self: *MCPTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn freeConfigs(allocator: std.mem.Allocator, configs: []MCPServerConfig) void {
        for (configs) |cfg| {
            allocator.free(cfg.name);
            allocator.free(cfg.command);
            if (cfg.url) |u| allocator.free(u);
            for (cfg.args) |a| allocator.free(a);
            allocator.free(cfg.args);
        }
        allocator.free(configs);
    }

    pub fn execute(_: *MCPTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const server = root.getString(args, "server") orelse {
            return ToolResult.fail("server is required");
        };
        const configs = loadServerConfigs(allocator) catch {
            return ToolResult.fail("Failed to load MCP config: no config file with an mcp_servers array (knot3bot.json or ~/.knot3bot/config.json)");
        };
        defer freeConfigs(allocator, configs);

        const cfg = for (configs) |cfg| {
            if (std.mem.eql(u8, cfg.name, server)) break cfg;
        } else {
            return ToolResult.fail("Unknown MCP server");
        };

        const action = root.getString(args, "action") orelse
            (if (root.getString(args, "tool") != null) "call" else "list_tools");

        if (std.mem.eql(u8, action, "list_tools")) {
            const tools_json = listTools(allocator, cfg) catch |err| {
                return ToolResult.fail(@errorName(err));
            };
            defer allocator.free(tools_json);
            return ToolResult.ok(tools_json);
        }

        const mcp_tool_name = root.getString(args, "tool") orelse {
            return ToolResult.fail("tool is required for action=call");
        };
        var arguments_json: []const u8 = "";
        var arguments_str: ?[]const u8 = null;
        defer if (arguments_str) |s| allocator.free(s);
        if (args.get("arguments")) |arg_val| {
            if (arg_val == .object) {
                arguments_str = std.json.Stringify.valueAlloc(allocator, arg_val, .{}) catch null;
                arguments_json = arguments_str orelse "";
            }
        }

        const output = callTool(allocator, cfg, mcp_tool_name, arguments_json) catch |err| {
            return ToolResult.fail(@errorName(err));
        };
        return ToolResult.ok(output);
    }

    pub const vtable = root.ToolVTable(@This());
};

/// MCP List Servers Tool — list servers configured in the config file.
pub const MCPListServersTool = struct {
    pub const tool_name = "mcp_list_servers";
    pub const tool_description = "List MCP servers configured in the knot3bot config file (mcp_servers array) with their commands.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{}}";

    pub fn tool(self: *MCPListServersTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *MCPListServersTool, allocator: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        const configs = loadServerConfigs(allocator) catch {
            return ToolResult.ok("{\"servers\":[],\"note\":\"No config file with an mcp_servers array found (knot3bot.json or ~/.knot3bot/config.json).\"}");
        };
        defer {
            for (configs) |cfg| {
                allocator.free(cfg.name);
                allocator.free(cfg.command);
                if (cfg.url) |u| allocator.free(u);
                for (cfg.args) |a| allocator.free(a);
                allocator.free(cfg.args);
            }
            allocator.free(configs);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        try out.appendSlice(allocator, "{\"servers\":[");
        for (configs, 0..) |cfg, i| {
            if (i > 0) try out.appendSlice(allocator, ",");
            try out.appendSlice(allocator, "{\"name\":\"");
            try out.appendSlice(allocator, cfg.name);
            if (cfg.url) |u| {
                try out.appendSlice(allocator, "\",\"url\":\"");
                try out.appendSlice(allocator, u);
            } else {
                try out.appendSlice(allocator, "\",\"command\":\"");
                try out.appendSlice(allocator, cfg.command);
            }
            try out.appendSlice(allocator, "\"}");
        }
        try out.appendSlice(allocator, "]}");
        return ToolResult.ok(try out.toOwnedSlice(allocator));
    }

    pub const vtable = root.ToolVTable(@This());
};
