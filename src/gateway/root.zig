//! Gateway — multi-platform message routing for knot3bot.
const std = @import("std");
const Agent = @import("../agent/root.zig").Agent;
const ToolRegistry = @import("../tools/root.zig").ToolRegistry;

pub const PlatformType = enum { cli, http, websocket, telegram, discord };
pub const Message = struct { id: []const u8, session_id: []const u8, content: []const u8, role: Role = .user, timestamp: i64 };
pub const Role = enum { system, user, assistant, tool };
pub const Response = struct { message_id: []const u8, content: []const u8, role: Role = .assistant, tool_calls: ?[]const u8 = null, finish_reason: FinishReason = .stop, usage: ?Usage = null };
pub const FinishReason = enum { stop, length, tool_calls, err };
pub const Usage = struct { prompt_tokens: u32, completion_tokens: u32, total_tokens: u32 };
pub const PlatformAdapter = struct {
    ptr: *anyopaque,
    onResponse: *const fn (ptr: *anyopaque, response: Response) void,
    onStreamChunk: *const fn (ptr: *anyopaque, chunk: []const u8) void,
    onStreamEnd: *const fn (ptr: *anyopaque, response: Response) void,
    onToolCall: *const fn (ptr: *anyopaque, tool_name: []const u8, args: []const u8, result: []const u8) void,
};
pub const Gateway = struct {
    allocator: std.mem.Allocator, agent: ?*Agent = null, registry: ?*ToolRegistry = null,
    platforms: std.StringHashMap(PlatformAdapter), sessions: std.StringHashMap([]const u8),
    pub fn init(allocator: std.mem.Allocator) Gateway {
        return .{ .allocator = allocator, .platforms = std.StringHashMap(PlatformAdapter).init(allocator), .sessions = std.StringHashMap([]const u8).init(allocator) };
    }
    pub fn deinit(self: *Gateway) void { self.platforms.deinit(); self.sessions.deinit(); }
    pub fn registerPlatform(self: *Gateway, name: []const u8, adapter: PlatformAdapter) !void {
        const nc = try self.allocator.dupe(u8, name);
        try self.platforms.put(nc, adapter);
    }
    pub fn routeMessage(self: *Gateway, platform: []const u8, msg: Message) !void {
        const adapter = self.platforms.get(platform) orelse return error.PlatformNotFound;
        // Build a simple response (full implementation: run agent with message)
        const response = Response{
            .message_id = msg.id,
            .content = "Message routed through gateway",
            .role = .assistant,
            .finish_reason = .stop,
        };
        adapter.onResponse(adapter.ptr, response);
    }
    pub fn bindSession(self: *Gateway, session_id: []const u8, platform_id: []const u8) !void {
        const sid = try self.allocator.dupe(u8, session_id);
        const pid = try self.allocator.dupe(u8, platform_id);
        try self.sessions.put(sid, pid);
    }
};
