//! MCP client tests — exercised against a fake JSON-RPC stdio server
//! (python3 speaking the MCP wire format) plus config parsing.

const std = @import("std");
const testing = std.testing;
const mcp = @import("mcp_tool.zig");
const shared = @import("../shared/root.zig");

const fake_server_script =
    \\
    \\import sys, json
    \\while True:
    \\    line = sys.stdin.readline()
    \\    if not line:
    \\        break
    \\    line = line.strip()
    \\    if not line:
    \\        continue
    \\    req = json.loads(line)
    \\    if "id" not in req:
    \\        continue
    \\    method = req.get("method", "")
    \\    if method == "initialize":
    \\        result = {"protocolVersion": "2024-11-05", "capabilities": {}, "serverInfo": {"name": "fake", "version": "0"}}
    \\    elif method == "tools/list":
    \\        result = {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}
    \\    elif method == "tools/call":
    \\        text = req["params"]["arguments"].get("text", "")
    \\        result = {"content": [{"type": "text", "text": "echo:" + text}], "isError": False}
    \\    else:
    \\        result = {}
    \\    sys.stdout.write(json.dumps({"jsonrpc": "2.0", "id": req["id"], "result": result}) + "\n")
    \\    sys.stdout.flush()
;

// The global_single_threaded Io fallback cannot spawn subprocesses in a
// test binary — install a real Threaded instance once, shared by all tests.
var g_threaded: ?std.Io.Threaded = null;
var empty_environ = std.process.Environ.Map{ .array_hash_map = .empty, .allocator = std.heap.page_allocator };

fn ensureIo() void {
    if (g_threaded == null) {
        g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
        shared.context.init(g_threaded.?.io(), &empty_environ, std.heap.page_allocator);
    }
}

const fake_config = mcp.MCPServerConfig{
    .name = "fake",
    .command = "python3",
    .args = &.{ "-c", fake_server_script },
};

test "loadServerConfigsFrom parses mcp_servers array" {
    const allocator = testing.allocator;
    const path = "/tmp/knot3bot_mcp_test_config.json";
    defer shared.context.cwdDeleteFile(path) catch {};

    try shared.context.cwdWriteFile(path,
        \\{
        \\  "mcp_servers": [
        \\    { "name": "fs", "command": "npx", "args": ["-y", "server-fs", "/tmp"] },
        \\    { "name": "web", "url": "http://127.0.0.1:9999" }
        \\  ]
        \\}
    );

    const configs = try mcp.loadServerConfigsFrom(allocator, path);
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

    try testing.expectEqual(@as(usize, 2), configs.len);
    try testing.expectEqualStrings("fs", configs[0].name);
    try testing.expectEqualStrings("npx", configs[0].command);
    try testing.expectEqual(@as(usize, 3), configs[0].args.len);
    try testing.expectEqualStrings("server-fs", configs[0].args[1]);
    try testing.expectEqualStrings("web", configs[1].name);
    try testing.expect(configs[1].url != null);
}

test "MCP listTools returns server tool descriptors" {
    ensureIo();
    const allocator = testing.allocator;
    const tools_json = try mcp.listTools(allocator, fake_config);
    defer allocator.free(tools_json);
    try testing.expect(std.mem.indexOf(u8, tools_json, "\"echo\"") != null);
    try testing.expect(std.mem.indexOf(u8, tools_json, "Echo text") != null);
}

test "MCP callTool round trips arguments and content" {
    ensureIo();
    const allocator = testing.allocator;
    const output = try mcp.callTool(allocator, fake_config, "echo", "{\"text\":\"hello world\"}");
    defer allocator.free(output);
    try testing.expectEqualStrings("echo:hello world", output);
}

test "MCP callTool passes empty arguments object" {
    ensureIo();
    const allocator = testing.allocator;
    const output = try mcp.callTool(allocator, fake_config, "echo", "");
    defer allocator.free(output);
    try testing.expectEqualStrings("echo:", output);
}
