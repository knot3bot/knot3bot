//! ACP (Agent Client Protocol) Adapter
//!
//! This adapter enables knot3bot to run as a coding agent inside IDEs like
//! VS Code, Zed, and JetBrains via the Agent Client Protocol.
//!
//! ACP uses JSON-RPC over stdio to communicate between the IDE and agent.

const std = @import("std");
const Agent = @import("../agent/root.zig").Agent;
const AgentConfig = Agent.AgentConfig;
const ToolRegistry = @import("../tools/root.zig").ToolRegistry;
const createDefaultSystemPrompt = @import("../agent/root.zig").createDefaultSystemPrompt;

/// ACP Message types
pub const AcpMessage = struct {
    jsonrpc: []const u8,
    id: ?usize = null,
    method: ?[]const u8 = null,
    params: ?std.json.Value = null,
    result: ?std.json.Value = null,
    err: ?AcpError = null,
};

/// ACP Error
pub const AcpError = struct {
    code: i32,
    message: []const u8,
};

/// ACP Session info
pub const AcpSessionInfo = struct {
    session_id: []const u8,
};

/// ACP Adapter for IDE integration
pub const ACAdapter = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    session_id: ?[]const u8 = null,
    process: ?std.process.Child = null,
    stdin_writer: ?std.fs.File.Writer = null,
    stdout_reader: ?std.fs.File.Reader = null,
    next_id: usize = 0,
    agent: ?*Agent.Agent = null,

    pub fn init(allocator: std.mem.Allocator, cwd: []const u8) ACAdapter {
        return .{
            .allocator = allocator,
            .cwd = cwd,
            .session_id = null,
            .process = null,
            .stdin_writer = null,
            .stdout_reader = null,
            .next_id = 0,
            .agent = null,
        };
    }

    pub fn setAgent(self: *ACAdapter, agent: *Agent.Agent) void {
        self.agent = agent;
    }

    pub fn deinit(self: *ACAdapter) void {
        if (self.process) |*proc| {
            proc.kill() catch {};
            proc.wait() catch {};
        }
        self.* = undefined;
    }

    /// Connect to the copilot ACP server
    pub fn connect(self: *ACAdapter, command: []const u8, args: []const []const u8) !void {
        self.process = std.process.Child.init(&[_][]const u8{command}, self.allocator);
        self.process.?.cwd_dir = std.fs.cwd();
        self.process.?.argv = args;

        const stdout = try self.process.?.spawn();
        self.stdout_reader = stdout.reader();
        self.stdin_writer = (try self.process.?.spawn()).writer();

        // Start the process
        _ = try self.process.?.spawn();
    }

    /// Send a JSON-RPC request and wait for response
    fn sendRequest(self: *ACAdapter, method: []const u8, params: std.json.Value) !AcpMessage {
        self.next_id += 1;
        const id = self.next_id;

        var request = std.json.ObjectMap.init(self.allocator);
        defer request.deinit();
        try request.put("jsonrpc", std.json.Value{ .string = "2.0" });
        try request.put("id", std.json.Value{ .integer = @intCast(id) });
        try request.put("method", std.json.Value{ .string = method });
        try request.put("params", params);

        const request_str = try std.json.stringifyAlloc(self.allocator, std.json.Value{ .object = &request }, .{});
        defer self.allocator.free(request_str);

        try self.stdin_writer.?.print("{s}\n", .{request_str});
        try self.stdin_writer.?.flush();

        // Wait for response with matching id
        const deadline = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds() + 900; // 15 min timeout
        while (std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds() < deadline) {
            const line = try self.stdout_reader.?.readUntilDelimiterAlloc(self.allocator, '\n', 1024 * 1024);
            defer self.allocator.free(line);

            var parser = std.json.Parser.init(self.allocator, .{});
            defer parser.deinit();

            const response = try parser.parse(line);
            const obj = response.object orelse continue;

            if (obj.get("id")) |resp_id| {
                if (resp_id.integer == id) {
                    return AcpMessage{
                        .jsonrpc = "2.0",
                        .id = id,
                        .result = obj.get("result"),
                        .err = if (obj.get("error")) |e| AcpError{
                            .code = if (e.object) |o| o.get("code") orelse std.json.Value{ .integer = -32603 } else std.json.Value{ .integer = -32603 },
                            .message = if (e.object) |o| o.get("message") orelse std.json.Value{ .string = "Unknown error" } else std.json.Value{ .string = "Unknown error" },
                        } else null,
                    };
                }
            }
        }

        return error.Timeout;
    }

    /// Handle initialize method
    fn handleInitialize(_: *ACAdapter, message: AcpMessage) !AcpMessage {
        _ = message;
        return AcpMessage{
            .jsonrpc = "2.0",
            .id = 1,
            .result = std.json.Value{ .object = &.{
                .{ .key = "protocolVersion", .value = .{ .integer = 1 } },
                .{ .key = "serverInfo", .value = .{ .object = &.{
                    .{ .key = "name", .value = .{ .string = "knot3bot" } },
                    .{ .key = "version", .value = .{ .string = "0.0.1" } },
                } } },
            } },
        };
    }

    /// Handle session/new method
    fn handleSessionNew(self: *ACAdapter, message: AcpMessage) !AcpMessage {
        _ = message;
        const session_id = try std.fmt.allocPrint(self.allocator, "sess_{}", .{std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds()});
        self.session_id = session_id;
        return AcpMessage{
            .jsonrpc = "2.0",
            .id = 1,
            .result = std.json.Value{ .object = &.{
                .{ .key = "sessionId", .value = .{ .string = session_id } },
            } },
        };
    }

    /// Handle incoming ACP message
    pub fn handleMessage(self: *ACAdapter, message: AcpMessage) !AcpMessage {
        if (message.method) |method| {
            if (std.mem.eql(u8, method, "initialize")) {
                return self.handleInitialize(message);
            } else if (std.mem.eql(u8, method, "session/new")) {
                return self.handleSessionNew(message);
            } else if (std.mem.eql(u8, method, "session/prompt")) {
                return self.handleSessionPrompt(message);
            }
        }

        return AcpMessage{
            .jsonrpc = "2.0",
            .id = message.id,
            .err = &.{ .code = -32601, .message = "Method not found" },
        };
    }

    /// Handle session/prompt - send prompt to copilot and collect response
    fn handleSessionPrompt(self: *ACAdapter, message: AcpMessage) !AcpMessage {
        const params = message.params orelse return error.InvalidParams;
        const obj = params.object orelse return error.InvalidParams;

        const session_id = obj.get("sessionId") orelse return error.InvalidParams;
        const prompt = obj.get("prompt") orelse return error.InvalidParams;

        // Extract text from prompt array
        var prompt_text = std.array_list.AlignedManaged(u8, null).init(self.allocator);
        defer prompt_text.deinit();

        if (prompt.array) |arr| {
            for (arr.items) |item| {
                if (item.object) |o| {
                    if (std.mem.eql(u8, (o.get("type") orelse std.json.Value{ .string = "" }).string, "text")) {
                        if (o.get("text")) |t| {
                            try prompt_text.writer().print("{s}", .{t.string});
                        }
                    }
                }
            }
        }

        // Use local agent if available, otherwise forward to remote ACP server
        if (self.agent) |agent| {
            const answer = agent.run(prompt_text.items) catch {
                return AcpMessage{
                    .jsonrpc = "2.0",
                    .id = message.id,
                    .result = std.json.Value{ .object = &.{
                        .{ .key = "text", .value = .{ .string = "Agent execution failed" } },
                    } },
                };
            };
            defer agent.allocator.free(answer);
            return AcpMessage{
                .jsonrpc = "2.0",
                .id = message.id,
                .result = std.json.Value{ .object = &.{
                    .{ .key = "text", .value = .{ .string = answer } },
                } },
            };
        }

        const request_params = std.json.Value{ .object = &.{
            .{ .key = "sessionId", .value = session_id },
            .{ .key = "prompt", .value = prompt },
        } };

        const response = self.sendRequest("session/prompt", request_params) catch {
            return AcpMessage{
                .jsonrpc = "2.0",
                .id = message.id,
                .result = std.json.Value{ .object = &.{
                    .{ .key = "text", .value = .{ .string = "ACP connection not available" } },
                } },
            };
        };

        return AcpMessage{
            .jsonrpc = "2.0",
            .id = message.id,
            .result = response.result,
        };
    }
};
