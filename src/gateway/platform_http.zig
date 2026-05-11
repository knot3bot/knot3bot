//! HTTP platform adapter — connects HTTP/SSE requests to the gateway.
//!
//! Implements PlatformAdapter for the HTTP server.
//! Writes streaming responses via SSE and formats JSON responses.

const std = @import("std");
const gateway = @import("root.zig");

pub const HttpPlatform = struct {
    allocator: std.mem.Allocator,
    gw: *gateway.Gateway,
    /// Active SSE connections keyed by request ID
    sse_connections: std.StringHashMap(*SseConnection),

    pub fn init(allocator: std.mem.Allocator, gw: *gateway.Gateway) HttpPlatform {
        return .{
            .allocator = allocator,
            .gw = gw,
            .sse_connections = std.StringHashMap(*SseConnection).init(allocator),
        };
    }

    pub fn deinit(self: *HttpPlatform) void {
        self.sse_connections.deinit();
    }

    pub fn adapter(self: *HttpPlatform) gateway.PlatformAdapter {
        return .{
            .ptr = @ptrCast(self),
            .onResponse = handleResponse,
            .onStreamChunk = handleStreamChunk,
            .onStreamEnd = handleStreamEnd,
            .onToolCall = handleToolCall,
        };
    }

    fn handleResponse(ptr: *anyopaque, response: gateway.Response) void {
        _ = ptr;
        _ = response;
        // HTTP responses are sent via the HTTP handler, not through platform adapter
    }

    fn handleStreamChunk(ptr: *anyopaque, chunk: []const u8) void {
        _ = ptr;
        _ = chunk;
        // SSE chunks are handled by the HTTP handler's streaming callback
    }

    fn handleStreamEnd(ptr: *anyopaque, response: gateway.Response) void {
        _ = ptr;
        _ = response;
    }

    fn handleToolCall(ptr: *anyopaque, tool_name: []const u8, args: []const u8, result: []const u8) void {
        _ = ptr;
        std.log.info("[Gateway:HTTP] Tool call: {s}({s})", .{ tool_name, args });
        _ = result;
    }
};

const SseConnection = struct {
    request_id: []const u8,
    fd: i32,
};
