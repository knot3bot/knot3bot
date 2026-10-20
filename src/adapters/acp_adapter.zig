//! ACP (Agent Client Protocol) Adapter — JSON-RPC over stdio.
//!
//! Lets IDEs (VS Code, Zed, JetBrains) drive knot3bot via `--acp`: each
//! request line on stdin is answered with one response line on stdout.
//!
//! Implemented methods (minimal but functional subset of ACP):
//!   initialize      -> protocol version + server info
//!   session/new     -> fresh session id
//!   session/prompt  -> runs the agent, returns the final answer as text
//!
//! The full ACP surface (session/update streaming notifications, fs/tool
//! bridging, server-initiated requests) is out of scope for this adapter.

const std = @import("std");
const shared = @import("../shared/context.zig");
const Agent = @import("../agent/root.zig").Agent;

const max_message_bytes = 1024 * 1024;

/// Serves ACP over stdin/stdout, driven by the provided agent.
pub const AcpServer = struct {
    allocator: std.mem.Allocator,
    agent: *Agent.Agent,

    pub fn init(allocator: std.mem.Allocator, agent: *Agent.Agent) AcpServer {
        return .{ .allocator = allocator, .agent = agent };
    }

    /// Read request lines from stdin until EOF; write one response line each.
    pub fn serveStdio(self: *AcpServer, io: std.Io) !void {
        const stdin_file = std.Io.File.stdin();
        var read_buf: [4096]u8 = undefined;
        var stdin = stdin_file.reader(io, &read_buf);

        const stdout_file = std.Io.File.stdout();
        var write_buf: [4096]u8 = undefined;
        var stdout = stdout_file.writer(io, &write_buf);

        var line_buf: std.ArrayList(u8) = .empty;
        defer line_buf.deinit(self.allocator);
        var chunk: [1]u8 = undefined;

        while (true) {
            line_buf.clearRetainingCapacity();
            var hit_eof = false;
            while (true) {
                const n = stdin.interface.readSliceShort(&chunk) catch break;
                if (n == 0) {
                    hit_eof = true;
                    break;
                }
                if (chunk[0] == '\n') break;
                try line_buf.append(self.allocator, chunk[0]);
                if (line_buf.items.len > max_message_bytes) return error.MessageTooLong;
            }
            if (line_buf.items.len == 0 and hit_eof) return; // EOF
            if (line_buf.items.len == 0) continue;

            const response = self.handleLine(line_buf.items) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => try self.composeError(null, -32700, "Parse error"),
            };
            defer self.allocator.free(response);
            try stdout.interface.writeAll(response);
            try stdout.interface.writeAll("\n");
            try stdout.interface.flush();
        }
    }

    fn handleLine(self: *AcpServer, line: []const u8) ![]const u8 {
        var parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, line, .{});
        defer parsed.deinit();
        if (parsed.value != .object) return error.ParseError;
        const obj = parsed.value.object;

        const id_val = obj.get("id");
        const method_val = obj.get("method") orelse return error.ParseError;
        if (method_val != .string) return error.ParseError;
        const method = method_val.string;

        if (std.mem.eql(u8, method, "initialize")) {
            const result = try self.handleInitialize();
            defer self.allocator.free(result);
            return self.composeResponse(id_val, result);
        } else if (std.mem.eql(u8, method, "session/new")) {
            const result = try self.handleSessionNew();
            defer self.allocator.free(result);
            return self.composeResponse(id_val, result);
        } else if (std.mem.eql(u8, method, "session/prompt")) {
            const result = self.handleSessionPrompt(obj.get("params")) catch {
                return self.composeError(id_val, -32000, "Agent execution failed");
            };
            defer self.allocator.free(result);
            return self.composeResponse(id_val, result);
        }
        return self.composeError(id_val, -32601, "Method not found");
    }

    fn handleInitialize(self: *AcpServer) ![]const u8 {
        var server_info: std.json.ObjectMap = .empty;
        defer server_info.deinit(self.allocator);
        try server_info.put(self.allocator, "name", .{ .string = "knot3bot" });
        try server_info.put(self.allocator, "version", .{ .string = @import("config").release_version });
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(self.allocator);
        try result.put(self.allocator, "protocolVersion", .{ .integer = 1 });
        try result.put(self.allocator, "serverInfo", .{ .object = server_info });
        return std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = result }, .{});
    }

    fn handleSessionNew(self: *AcpServer) ![]const u8 {
        var result: std.json.ObjectMap = .empty;
        defer result.deinit(self.allocator);
        const session_id = try std.fmt.allocPrint(self.allocator, "sess_{d}", .{shared.timestamp()});
        defer self.allocator.free(session_id);
        try result.put(self.allocator, "sessionId", .{ .string = session_id });
        return std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = result }, .{});
    }

    /// Extract the text items from an ACP prompt array and run the agent.
    fn handleSessionPrompt(self: *AcpServer, params: ?std.json.Value) ![]const u8 {
        const p = params orelse return error.InvalidParams;
        if (p != .object) return error.InvalidParams;
        const prompt_val = p.object.get("prompt") orelse return error.InvalidParams;
        if (prompt_val != .array) return error.InvalidParams;

        var prompt_text: std.ArrayList(u8) = .empty;
        defer prompt_text.deinit(self.allocator);
        for (prompt_val.array.items) |item| {
            if (item != .object) continue;
            const item_type = item.object.get("type") orelse continue;
            if (item_type != .string or !std.mem.eql(u8, item_type.string, "text")) continue;
            const text = item.object.get("text") orelse continue;
            if (text == .string) try prompt_text.appendSlice(self.allocator, text.string);
        }

        // The agent allocates from the process arena (see main.zig) — the
        // arena owns the answer; do not free it with a different allocator.
        const answer = try self.agent.run(prompt_text.items);

        var result: std.json.ObjectMap = .empty;
        defer result.deinit(self.allocator);
        try result.put(self.allocator, "text", .{ .string = answer });
        return std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = result }, .{});
    }

    fn composeResponse(self: *AcpServer, id_val: ?std.json.Value, result_json: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try appendJsonId(self.allocator, &out, id_val);
        try out.appendSlice(self.allocator, ",\"result\":");
        try out.appendSlice(self.allocator, result_json);
        try out.appendSlice(self.allocator, "}");
        return out.toOwnedSlice(self.allocator);
    }

    fn composeError(self: *AcpServer, id_val: ?std.json.Value, code: i32, message: []const u8) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, "{\"jsonrpc\":\"2.0\",\"id\":");
        try appendJsonId(self.allocator, &out, id_val);
        try out.appendSlice(self.allocator, ",\"error\":{\"code\":");
        const code_str = try std.fmt.allocPrint(self.allocator, "{d}", .{code});
        defer self.allocator.free(code_str);
        try out.appendSlice(self.allocator, code_str);
        try out.appendSlice(self.allocator, ",\"message\":\"");
        for (message) |c| {
            if (c == '"') {
                try out.append(self.allocator, '\\');
                try out.append(self.allocator, '"');
            } else {
                try out.append(self.allocator, c);
            }
        }
        try out.appendSlice(self.allocator, "\"}}");
        return out.toOwnedSlice(self.allocator);
    }

    fn appendJsonId(allocator: std.mem.Allocator, out: *std.ArrayList(u8), id_val: ?std.json.Value) !void {
        if (id_val) |v| {
            if (v == .integer) {
                const s = try std.fmt.allocPrint(allocator, "{d}", .{v.integer});
                defer allocator.free(s);
                try out.appendSlice(allocator, s);
                return;
            }
            if (v == .string) {
                try out.append(allocator, '"');
                try out.appendSlice(allocator, v.string);
                try out.append(allocator, '"');
                return;
            }
        }
        try out.appendSlice(allocator, "null");
    }
};
