//! Gateway — multi-platform message routing for knot3bot.
//!
//! Inspired by Hermes Agent's gateway system. Provides a unified abstraction
//! for handling messages from different platforms (CLI, HTTP, WebSocket, etc.).
//!
//! Architecture:
//!   Platform → Gateway → Agent → Gateway → Platform
//!
//! The Gateway owns the agent instance and routes messages between platforms
//! and the agent. Each platform registers with the gateway and receives
//! responses for its sessions.

const std = @import("std");
const Agent = @import("../agent/root.zig").Agent;
const ToolRegistry = @import("../tools/root.zig").ToolRegistry;

pub const PlatformType = enum {
    cli,
    http,
    websocket,
    telegram,  // future
    discord,   // future
};

pub const Message = struct {
    id: []const u8,
    session_id: []const u8,
    content: []const u8,
    role: Role = .user,
    timestamp: i64,
};

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const Response = struct {
    message_id: []const u8,
    content: []const u8,
    role: Role = .assistant,
    tool_calls: ?[]const u8 = null,
    finish_reason: FinishReason = .stop,
    usage: ?Usage = null,
};

pub const FinishReason = enum {
    stop,
    length,
    tool_calls,
    err,
};

pub const Usage = struct {
    prompt_tokens: u32,
    completion_tokens: u32,
    total_tokens: u32,
};

/// Platform adapter interface — each platform implements these callbacks.
pub const PlatformAdapter = struct {
    ptr: *anyopaque,
    /// Called when the agent produces a response for this platform
    onResponse: *const fn (ptr: *anyopaque, response: Response) void,
    /// Called when the agent produces a streaming chunk
    onStreamChunk: *const fn (ptr: *anyopaque, chunk: []const u8) void,
    /// Called when the agent finishes streaming
    onStreamEnd: *const fn (ptr: *anyopaque, response: Response) void,
    /// Called when there's a tool call result
    onToolCall: *const fn (ptr: *anyopaque, tool_name: []const u8, args: []const u8, result: []const u8) void,
};

pub const Gateway = struct {
    allocator: std.mem.Allocator,
    agent: ?*Agent = null,
    registry: ?*ToolRegistry = null,
    platforms: std.StringHashMap(PlatformAdapter),
    sessions: std.StringHashMap([]const u8), // session_id → platform_id

    pub fn init(allocator: std.mem.Allocator) Gateway {
        return .{
            .allocator = allocator,
            .platforms = std.StringHashMap(PlatformAdapter).init(allocator),
            .sessions = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *Gateway) void {
        var it = self.platforms.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.platforms.deinit();
        self.sessions.deinit();
    }

    /// Register a platform with the gateway
    pub fn registerPlatform(self: *Gateway, name: []const u8, adapter: PlatformAdapter) !void {
        const name_copy = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(name_copy);
        try self.platforms.put(name_copy, adapter);
    }

    /// Route a message from a platform through the agent
    pub fn routeMessage(self: *Gateway, platform: []const u8, msg: Message) !void {
        const adapter = self.platforms.get(platform) orelse return;
        _ = adapter;
        _ = msg;
        // In full implementation: run agent with message, stream response to platform
    }

    /// Associate a session with a platform
    pub fn bindSession(self: *Gateway, session_id: []const u8, platform_id: []const u8) !void {
        const sid = try self.allocator.dupe(u8, session_id);
        const pid = try self.allocator.dupe(u8, platform_id);
        try self.sessions.put(sid, pid);
    }
};
