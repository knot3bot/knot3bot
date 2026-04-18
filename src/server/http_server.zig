//! HTTP API server with OpenAI-compatible endpoints
//! Production-grade with request limits, timeouts, structured logging

const std = @import("std");
const shared = @import("../shared/context.zig");
const Agent = @import("../agent/root.zig").Agent;
const AgentConfig = Agent.AgentConfig;
const ToolRegistry = @import("../tools/root.zig").ToolRegistry;
const createDefaultSystemPrompt = @import("../agent/root.zig").createDefaultSystemPrompt;
const SqliteMemorySystem = @import("../memory/sqlite.zig").SqliteMemorySystem;
const providers = @import("../providers/root.zig");
const rate_limiter_mod = @import("rate_limiter.zig");
const circuit_breaker = @import("circuit_breaker.zig");
const Provider = providers.Provider;
const context_compressor_mod = @import("../agent/context_compressor.zig");
const trajectory_mod = @import("../agent/trajectory.zig");
const models = @import("../models.zig");
const MemoryManager = @import("../memory/root.zig").MemoryManager;
const ManagerMemoryBackend = @import("../memory/root.zig").ManagerMemoryBackend;
const MemorySystem = @import("../memory/root.zig").MemorySystem;

/// Maximum request body size (1MB) - protects against buffer overflow
const MAX_REQUEST_SIZE = 1024 * 1024;

/// Graceful shutdown timeout for connection draining (seconds)
const GRACEFUL_SHUTDOWN_TIMEOUT = 10;

// ============================================================================
// Authentication Configuration
// ============================================================================

pub const AuthConfig = struct {
    require_auth: bool = true,
    api_keys: []const []const u8,
    allowed_origins: []const []const u8,

    pub fn validateKey(self: *const AuthConfig, key: []const u8) bool {
        for (self.api_keys) |valid_key| {
            if (std.mem.eql(u8, key, valid_key)) return true;
        }
        return false;
    }

    pub fn validateOrigin(self: *const AuthConfig, origin: []const u8) bool {
        if (self.allowed_origins.len == 0) return true;
        for (self.allowed_origins) |allowed| {
            if (std.mem.eql(u8, origin, allowed) or std.mem.eql(u8, origin, "*")) return true;
        }
        return false;
    }
};

// ============================================================================
// Server Configuration
// ============================================================================

pub const ServerConfig = struct {
    /// Maximum request body size in bytes (default: 1MB)
    max_request_size: usize = MAX_REQUEST_SIZE,
    /// Enable streaming responses (default: true)
    enable_streaming: bool = true,
    /// Shutdown timeout for graceful drain in seconds (default: 10s)
    graceful_shutdown_timeout: u32 = GRACEFUL_SHUTDOWN_TIMEOUT,
    /// Rate limit: max requests per window (default: 100)
    rate_limit_requests: u32 = 100,
    /// Rate limit: window size in seconds (default: 60)
    rate_limit_window_secs: u32 = 60,
};

// ============================================================================
// Server Metrics (Enhanced)
// ============================================================================

pub const ServerMetrics = struct {
    total_requests: u64 = 0,
    chat_requests: u64 = 0,
    streaming_requests: u64 = 0,
    error_count: u64 = 0,
    total_response_time_ms: u64 = 0,
    request_size_errors: u64 = 0,
    rate_limit_exceeded: u64 = 0,
    circuit_breaker_rejections: u64 = 0,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ServerMetrics {
        return .{ .allocator = allocator };
    }

    pub fn record(self: *ServerMetrics, endpoint: []const u8, duration_ms: u64, is_error: bool) void {
        _ = endpoint;
        self.total_requests += 1;
        if (is_error) self.error_count += 1;
        self.total_response_time_ms += duration_ms;
    }

    pub fn recordRequestSizeError(self: *ServerMetrics) void {
        self.request_size_errors += 1;
    }
};

// ============================================================================
// Request ID Generator (Simple)
// ============================================================================

var request_counter: u64 = 0;

fn generateRequestId() []const u8 {
    request_counter += 1;
    const timestamp = shared.timestamp();
    const static = struct {
        var buf: [64]u8 = undefined;
    };
    const result = std.fmt.bufPrint(&static.buf, "{d}-{d}", .{ timestamp, request_counter }) catch unreachable;
    return result;
}

fn streamWriteAllFd(fd: i32, data: []const u8) !void {
    var total_sent: usize = 0;
    while (total_sent < data.len) {
        const sent = std.c.send(fd, data[total_sent..].ptr, data[total_sent..].len, 0);
        if (sent < 0) return error.WriteFailed;
        total_sent += @intCast(sent);
    }
}

fn streamWriteAll(conn: std.Io.net.Stream, data: []const u8) !void {
    return streamWriteAllFd(conn.socket.handle, data);
}

fn appendJsonEscaped(list: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '"' => try list.appendSlice(allocator, "\\\""),
            '\\' => try list.appendSlice(allocator, "\\\\"),
            '\n' => try list.appendSlice(allocator, "\\n"),
            '\r' => try list.appendSlice(allocator, "\\r"),
            '\t' => try list.appendSlice(allocator, "\\t"),
            else => try list.append(allocator, c),
        }
    }
}

// ============================================================================
// Main Server
// ============================================================================

pub const Server = struct {
    allocator: std.mem.Allocator,
    agent_config: AgentConfig,
    registry: *const ToolRegistry,
    port: u16,
    shutdown_flag: *std.atomic.Value(bool),
    db_path: ?[]const u8,
    config: ServerConfig,
    start_time: i64,
    metrics: ServerMetrics,
    auth_config: AuthConfig,
    rate_limiter: rate_limiter_mod.RateLimiter,
    circuit_brk: circuit_breaker.CircuitBreaker,
    context_compressor: ?context_compressor_mod.ContextCompressor = null,
    trajectory_recorder: ?trajectory_mod.TrajectoryRecorder = null,
    model_registry: ?*models.ModelRegistry = null,
    memory_manager: MemoryManager,
    in_memory: MemorySystem,
    sqlite_memory: ?SqliteMemorySystem = null,
    backends: []ManagerMemoryBackend,

    pub fn init(
        allocator: std.mem.Allocator,
        agent_config: AgentConfig,
        registry: *const ToolRegistry,
        port: u16,
        shutdown_flag: *std.atomic.Value(bool),
        db_path: ?[]const u8,
        auth_config: AuthConfig,
        config: ServerConfig,
    ) !Server {
        var server = Server{
            .allocator = allocator,
            .agent_config = agent_config,
            .registry = registry,
            .port = port,
            .shutdown_flag = shutdown_flag,
            .db_path = db_path,
            .config = config,
            .start_time = shared.timestamp(),
            .metrics = ServerMetrics.init(allocator),
            .auth_config = auth_config,
            .rate_limiter = rate_limiter_mod.RateLimiter.init(allocator, .{ .max_requests = config.rate_limit_requests, .window_ms = config.rate_limit_window_secs * 1000 }),
            .circuit_brk = circuit_breaker.CircuitBreaker.init(.{}),
            .in_memory = MemorySystem.init(allocator),
            .sqlite_memory = if (db_path) |p| try SqliteMemorySystem.init(allocator, p) else null,
            .backends = &.{},
            .memory_manager = undefined,
        };

        const backend_count: usize = if (server.sqlite_memory != null) 2 else 1;
        server.backends = try allocator.alloc(ManagerMemoryBackend, backend_count);
        server.backends[0] = .{ .memory = &server.in_memory };
        if (server.sqlite_memory) |*s| server.backends[1] = .{ .sqlite = s };
        server.memory_manager = MemoryManager.init(allocator, server.backends);

        return server;
    }

    pub fn deinit(self: *Server) void {
        self.memory_manager.deinit();
        self.in_memory.deinit();
        if (self.sqlite_memory) |*s| s.deinit();
        self.allocator.free(self.backends);
        self.rate_limiter.deinit();
        if (self.context_compressor) |*cc| {
            cc.deinit();
        }
    }

    pub fn start(self: *Server) !void {
        const io = shared.io();
        const address = try std.Io.net.IpAddress.parseIp4("0.0.0.0", self.port);
        var tcp_server = try address.listen(io, .{
            .reuse_address = true,
        });
        defer tcp_server.deinit(io);

        std.log.info("Server listening on http://0.0.0.0:{d}/", .{self.port});
        std.log.info("Provider: {s}  Model: {s}", .{ self.agent_config.provider.name(), self.agent_config.model });
        std.log.info("Max request size: {d} bytes", .{self.config.max_request_size});

        while (!self.shutdown_flag.load(.monotonic)) {
            const conn = tcp_server.accept(io) catch |err| {
                if (self.shutdown_flag.load(.monotonic)) break;
                std.log.debug("Accept error: {s}", .{@errorName(err)});
                continue;
            };
            defer conn.close(io);

            self.handleConnection(conn) catch |err| {
                std.log.err("Connection error: {s}", .{@errorName(err)});
            };
        }

        std.log.info("Server shutdown complete", .{});
    }

    fn extractAuthHeader(request: []const u8) ?[]const u8 {
        const auth_prefix = "Authorization: ";
        if (std.mem.indexOf(u8, request, auth_prefix)) |auth_idx| {
            const value_start = auth_idx + auth_prefix.len;
            const line_end = std.mem.indexOfScalar(u8, request[value_start..], '\r') orelse request.len;
            return request[value_start .. value_start + line_end];
        }
        return null;
    }

    fn validateApiKey(self: *Server, auth_header: ?[]const u8) bool {
        if (!self.auth_config.require_auth) return true;
        const header = auth_header orelse return false;
        const bearer_prefix = "Bearer ";
        const token = if (std.mem.startsWith(u8, header, bearer_prefix)) header[bearer_prefix.len..] else header;
        return self.auth_config.validateKey(token);
    }

    fn handleConnection(self: *Server, conn: std.Io.net.Stream) !void {
        const request_id = generateRequestId();

        // Use dynamic buffer for request to handle large payloads
        var buf = try self.allocator.alloc(u8, self.config.max_request_size);
        defer self.allocator.free(buf);

        var stream_reader = std.Io.net.Stream.reader(conn, shared.io(), buf);
        var chunk_buf = [_][]u8{buf};
        const n = stream_reader.interface.readVec(&chunk_buf) catch |err| {
            std.log.err("[{s}] Read error: {s}", .{ request_id, @errorName(err) });
            return;
        };

        if (n == 0) return;

        // Check request size limit
        if (@as(usize, @intCast(n)) >= self.config.max_request_size) {
            self.metrics.recordRequestSizeError();
            std.log.warn("[{s}] Request size exceeded limit: {d} bytes", .{ request_id, n });
            try self.sendJson(conn, 413, "{\"error\":{\"message\":\"Request too large\",\"type\":\"request_too_large\"}}", request_id);
            return;
        }

        const request = buf[0..n];
        const start_time = shared.milliTimestamp();

        const auth_header = extractAuthHeader(request);

        // Per-key rate limiting
        const rl_identifier = blk: {
            if (auth_header) |ah| {
                const bearer_prefix = "Bearer ";
                if (std.mem.startsWith(u8, ah, bearer_prefix)) {
                    break :blk ah[bearer_prefix.len..];
                }
                break :blk ah;
            }
            break :blk "anonymous";
        };
        if (!self.rate_limiter.check(rl_identifier)) {
            self.metrics.rate_limit_exceeded += 1;
            std.log.warn("[{s}] Rate limit exceeded for {s}", .{ request_id, rl_identifier });
            try self.sendJson(conn, 429, "{\"error\":{\"message\":\"Rate limit exceeded\",\"type\":\"rate_limit_exceeded\"}}", request_id);
            return;
        }
        const method_end = std.mem.indexOfScalar(u8, request, ' ') orelse return;
        const path_start = method_end + 1;
        const path_end = std.mem.indexOfScalar(u8, request[path_start..], ' ') orelse return;
        const method = request[0..method_end];
        const path = request[path_start .. path_start + path_end];
        std.log.info("[{s}] {s} {s}", .{ request_id, method, path });

        if (std.mem.eql(u8, method, "GET")) {
            if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/index.html")) {
                try self.serveStaticFile(conn, "ui/index.html", "text/html; charset=utf-8", request_id);
            } else if (std.mem.eql(u8, path, "/health")) {
                try self.handleHealth(conn, request_id);
            } else if (std.mem.eql(u8, path, "/healthz")) {
                try self.sendJson(conn, 200, "{\"status\":\"ok\"}", request_id);
            } else if (std.mem.eql(u8, path, "/v1/models")) {
                try self.handleGetModels(conn, request_id);
            } else if (std.mem.eql(u8, path, "/metrics")) {
                try self.handleGetMetrics(conn, request_id);
            } else if (std.mem.eql(u8, path, "/ready")) {
                try self.handleReady(conn, request_id);
            } else if (std.mem.eql(u8, path, "/api/tools")) {
                try self.handleGetTools(conn, request_id);
            } else if (std.mem.eql(u8, path, "/api/config")) {
                try self.handleGetConfig(conn, request_id);
            } else {
                try self.sendJson(conn, 404, "{\"error\":{\"message\":\"Not found\"}}", request_id);
            }
        } else if (std.mem.eql(u8, method, "OPTIONS")) {
            try self.sendOptions(conn, request_id);
            if (std.mem.eql(u8, path, "/") or std.mem.eql(u8, path, "/health")) {
                try self.handleHealth(conn, request_id);
            } else if (std.mem.eql(u8, path, "/healthz")) {
                try self.sendJson(conn, 200, "{\"status\":\"ok\"}", request_id);
            } else if (std.mem.eql(u8, path, "/v1/models")) {
                try self.handleGetModels(conn, request_id);
            } else if (std.mem.eql(u8, path, "/metrics")) {
                try self.handleGetMetrics(conn, request_id);
            } else if (std.mem.eql(u8, path, "/ready")) {
                try self.handleReady(conn, request_id);
            } else {
                try self.sendJson(conn, 404, "{\"error\":{\"message\":\"Not found\"}}", request_id);
            }
        } else if (std.mem.eql(u8, method, "POST")) {
            if (!self.validateApiKey(auth_header)) {
                try self.sendJson(conn, 401, "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"invalid_api_key\"}}", request_id);
                return;
            }
            if (std.mem.eql(u8, path, "/v1/chat/completions")) {
                const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
                const body = request[header_end + 4 ..];
                try self.handleChatCompletion(conn, body, request_id);
            } else if (std.mem.eql(u8, path, "/v1/responses")) {
                const header_end = std.mem.indexOf(u8, request, "\r\n\r\n") orelse return;
                const body = request[header_end + 4 ..];
                try self.handleResponses(conn, body, request_id);
            } else {
                try self.sendJson(conn, 404, "{\"error\":{\"message\":\"Not found\"}}", request_id);
            }
        } else {
            try self.sendJson(conn, 405, "{\"error\":{\"message\":\"Method not allowed\"}}", request_id);
        }

        const duration = @as(u64, @intCast(shared.milliTimestamp() - start_time));
        self.metrics.record(path, duration, false);
        std.log.info("[{s}] Request completed in {d}ms", .{ request_id, duration });
    }

    fn handleChatCompletion(self: *Server, conn: std.Io.net.Stream, body: []const u8, request_id: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        self.metrics.chat_requests += 1;

        // Circuit breaker check
        if (!self.circuit_brk.allowRequest()) {
            self.metrics.circuit_breaker_rejections += 1;
            const remaining = self.circuit_brk.remainingTimeout();
            std.log.warn("[{s}] Circuit breaker OPEN, retry after {d}s", .{ request_id, remaining });
            const err_resp = try std.fmt.allocPrint(self.allocator, "{{\"error\":{{\"message\":\"Service temporarily unavailable\",\"type\":\"circuit_breaker_open\",\"retry_after_seconds\":{d}}}}}", .{remaining});
            defer self.allocator.free(err_resp);
            try self.sendJson(conn, 503, err_resp, request_id);
            return;
        }

        const parsed = std.json.parseFromSlice(ChatCompletionRequest, allocator, body, .{}) catch {
            try self.sendJson(conn, 400, "{\"error\":{\"message\":\"Invalid JSON\"}}", request_id);
            return;
        };
        defer parsed.deinit();

        const messages = parsed.value.messages;
        if (messages.len == 0) {
            try self.sendJson(conn, 400, "{\"error\":{\"message\":\"No messages provided\"}}", request_id);
            return;
        }

        // Validate request schema
        if (!validateChatRequest(&parsed.value)) {
            try self.sendJson(conn, 400, "{\"error\":{\"message\":\"Invalid request parameters\",\"type\":\"invalid_request\"}}", request_id);
            return;
        }

        const user_message = messages[messages.len - 1].content;
        const stream_requested = parsed.value.stream orelse false;

        const system_prompt = createDefaultSystemPrompt(allocator, self.registry) catch {
            try self.sendJson(conn, 500, "{\"error\":{\"message\":\"Failed to create system prompt\"}}", request_id);
            return;
        };

        const agent_config = AgentConfig{
            .max_iterations = self.agent_config.max_iterations,
            .system_prompt = system_prompt,
            .model = self.agent_config.model,
            .api_key = self.agent_config.api_key,
            .provider = self.agent_config.provider,
            .context_compressor = if (self.context_compressor) |cc| cc else null,
            .enable_trajectory_recording = self.trajectory_recorder != null,
            .trajectory_recorder = if (self.trajectory_recorder) |*tr| tr else null,
            .model_registry = self.model_registry,
            .enable_smart_routing = self.model_registry != null,
        };

        var agent = Agent.Agent.init(allocator, agent_config, self.registry);
        defer agent.deinit();

        if (messages.len > 1) {
            for (messages[0 .. messages.len - 1]) |msg| {
                const role: Agent.Role = if (std.mem.eql(u8, msg.role, "system")) .system else if (std.mem.eql(u8, msg.role, "user")) .user else if (std.mem.eql(u8, msg.role, "assistant")) .assistant else if (std.mem.eql(u8, msg.role, "tool")) .tool else .user;
                if (role == .system) continue;
                agent.appendMessage(role, msg.content) catch {};
            }
        }

        const session_id = parsed.value.session_id;
        if (session_id) |sid| {
            self.memory_manager.createSession(sid) catch {};
            for (messages) |msg| {
                self.memory_manager.addMessage(sid, msg.role, msg.content) catch {};
            }
        }

        if (stream_requested and self.config.enable_streaming) {
            self.metrics.streaming_requests += 1;
            const response = self.handleStreamingCompletion(conn, allocator, &agent, user_message, request_id) catch |err| {
                std.log.err("[{s}] Streaming error: {s}", .{ request_id, @errorName(err) });
                return;
            };
            defer allocator.free(response);
            if (session_id) |sid| {
                self.memory_manager.addMessage(sid, "assistant", response) catch {};
            }
        } else {
            const response = agent.run(user_message) catch |err| {
                std.log.err("[{s}] Agent error: {s}", .{ request_id, @errorName(err) });
                self.circuit_brk.recordFailure();
                try self.sendJson(conn, 500, "{\"error\":{\"message\":\"Agent execution failed\"}}", request_id);
                return;
            };
            self.circuit_brk.recordSuccess();
            defer allocator.free(response);

            if (session_id) |sid| {
                self.memory_manager.addMessage(sid, "assistant", response) catch {};
            }

            var json_buf = std.ArrayList(u8).empty;
            defer json_buf.deinit(self.allocator);

            const chat_id = std.fmt.allocPrint(self.allocator, "chatcmpl-{s}", .{request_id}) catch "chatcmpl-1";
            defer self.allocator.free(chat_id);

            try json_buf.appendSlice(self.allocator, "{\"id\":\"");
            try json_buf.appendSlice(self.allocator, chat_id);
            try json_buf.appendSlice(self.allocator, "\",\"object\":\"chat.completion\",\"created\":");
            {
                var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &json_buf);
                try allocating.writer.print("{}", .{shared.timestamp()});
                json_buf = allocating.toArrayList();
            }
            try json_buf.appendSlice(self.allocator, ",\"model\":\"");
            try json_buf.appendSlice(self.allocator, self.agent_config.model);
            try json_buf.appendSlice(self.allocator, "\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"");
            try appendJsonEscaped(&json_buf, self.allocator, response);
            try json_buf.appendSlice(self.allocator, "\"}}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}");
            try self.sendJson(conn, 200, try json_buf.toOwnedSlice(self.allocator), request_id);
        }
    }

    fn handleStreamingCompletion(
        self: *Server,
        conn: std.Io.net.Stream,
        allocator: std.mem.Allocator,
        agent: *Agent.Agent,
        user_message: []const u8,
        request_id: []const u8,
    ) ![]const u8 {
        const header = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: keep-alive\r\nAccess-Control-Allow-Origin: *\r\nX-Request-ID: ";
        try streamWriteAll(conn, header);
        try streamWriteAll(conn, request_id);
        try streamWriteAll(conn, "\r\n\r\n");

        const model_name = self.agent_config.model;

        const StreamCtx = struct {
            stream: std.Io.net.Stream,
            model_name: []const u8,
            request_id: []const u8,
        };
        const ctx = try allocator.create(StreamCtx);
        ctx.* = .{
            .stream = conn,
            .model_name = model_name,
            .request_id = request_id,
        };
        defer allocator.destroy(ctx);

        const callback = struct {
            fn cb(chunk: []const u8, ud: ?*anyopaque) void {
                const p = @as(*StreamCtx, @ptrFromInt(@intFromPtr(ud.?)));
                var buf: [8192]u8 = undefined;
                const ts = shared.timestamp();

                var pos: usize = 0;

                const appendSlice = struct {
                    fn run(buffer: *[8192]u8, position: *usize, data: []const u8) bool {
                        if (position.* + data.len > buffer.len) return false;
                        @memcpy(buffer[position.*..][0..data.len], data);
                        position.* += data.len;
                        return true;
                    }
                }.run;

                const appendByte = struct {
                    fn run(buffer: *[8192]u8, position: *usize, byte: u8) bool {
                        if (position.* >= buffer.len) return false;
                        buffer[position.*] = byte;
                        position.* += 1;
                        return true;
                    }
                }.run;

                if (!appendSlice(&buf, &pos, "data: {\"id\":\"chatcmpl-")) return;
                if (!appendSlice(&buf, &pos, p.request_id)) return;
                if (!appendSlice(&buf, &pos, "\",\"object\":\"chat.completion.chunk\",\"created\":")) return;

                const ts_slice = std.fmt.bufPrint(buf[pos..], "{d}", .{ts}) catch return;
                pos += ts_slice.len;

                if (!appendSlice(&buf, &pos, ",\"model\":\"")) return;
                if (!appendSlice(&buf, &pos, p.model_name)) return;
                if (!appendSlice(&buf, &pos, "\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"")) return;

                for (chunk) |c| {
                    switch (c) {
                        '\\' => {
                            if (!appendSlice(&buf, &pos, "\\\\")) return;
                        },
                        '"' => {
                            if (!appendSlice(&buf, &pos, "\\\"")) return;
                        },
                        '\n' => {
                            if (!appendSlice(&buf, &pos, "\\n")) return;
                        },
                        '\r' => {
                            if (!appendSlice(&buf, &pos, "\\r")) return;
                        },
                        else => {
                            if (!appendByte(&buf, &pos, c)) return;
                        },
                    }
                }

                if (!appendSlice(&buf, &pos, "\"}}]}\r\n")) return;

                streamWriteAll(p.stream, buf[0..pos]) catch return;
            }
        }.cb;

        const ctx_ptr = @as(?*anyopaque, @constCast(ctx));
        const response = agent.runStreaming(user_message, callback, ctx_ptr) catch |err| {
            std.log.err("[{s}] Streaming error: {s}", .{ request_id, @errorName(err) });
            self.circuit_brk.recordFailure();
            streamWriteAll(conn, "data: [DONE]\r\n\r\n") catch {};
            return error.StreamingFailed;
        };
        self.circuit_brk.recordSuccess();

        streamWriteAll(conn, "data: [DONE]\r\n\r\n") catch {};
        return response;
    }

    fn handleResponses(self: *Server, conn: std.Io.net.Stream, body: []const u8, request_id: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const allocator = arena.allocator();

        // Circuit breaker check
        if (!self.circuit_brk.allowRequest()) {
            self.metrics.circuit_breaker_rejections += 1;
            const remaining = self.circuit_brk.remainingTimeout();
            std.log.warn("[{s}] Circuit breaker OPEN, retry after {d}s", .{ request_id, remaining });
            const err_resp = try std.fmt.allocPrint(self.allocator, "{{\"error\":{{\"message\":\"Service temporarily unavailable\",\"type\":\"circuit_breaker_open\",\"retry_after_seconds\":{d}}}}}", .{remaining});
            defer self.allocator.free(err_resp);
            try self.sendJson(conn, 503, err_resp, request_id);
            return;
        }

        const parsed = std.json.parseFromSlice(ChatCompletionRequest, allocator, body, .{}) catch {
            try self.sendJson(conn, 400, "{\"error\":{\"message\":\"Invalid JSON\"}}", request_id);
            return;
        };
        defer parsed.deinit();

        const messages = parsed.value.messages;
        if (messages.len == 0) {
            try self.sendJson(conn, 400, "{\"error\":{\"message\":\"No messages provided\"}}", request_id);
            return;
        }

        if (!validateChatRequest(&parsed.value)) {
            try self.sendJson(conn, 400, "{\"error\":{\"message\":\"Invalid request parameters\",\"type\":\"invalid_request\"}}", request_id);
            return;
        }

        const user_message = messages[messages.len - 1].content;

        const system_prompt = createDefaultSystemPrompt(allocator, self.registry) catch {
            try self.sendJson(conn, 500, "{\"error\":{\"message\":\"Failed to create system prompt\"}}", request_id);
            return;
        };

        const agent_config = AgentConfig{
            .max_iterations = self.agent_config.max_iterations,
            .system_prompt = system_prompt,
            .model = self.agent_config.model,
            .api_key = self.agent_config.api_key,
            .provider = self.agent_config.provider,
            .context_compressor = if (self.context_compressor) |cc| cc else null,
            .enable_trajectory_recording = self.trajectory_recorder != null,
            .trajectory_recorder = if (self.trajectory_recorder) |*tr| tr else null,
            .model_registry = self.model_registry,
            .enable_smart_routing = self.model_registry != null,
        };

        var agent = Agent.Agent.init(allocator, agent_config, self.registry);
        defer agent.deinit();

        if (messages.len > 1) {
            for (messages[0 .. messages.len - 1]) |msg| {
                const role: Agent.Role = if (std.mem.eql(u8, msg.role, "system")) .system else if (std.mem.eql(u8, msg.role, "user")) .user else if (std.mem.eql(u8, msg.role, "assistant")) .assistant else if (std.mem.eql(u8, msg.role, "tool")) .tool else .user;
                if (role == .system) continue;
                agent.appendMessage(role, msg.content) catch {};
            }
        }

        const session_id = parsed.value.session_id;
        if (session_id) |sid| {
            self.memory_manager.createSession(sid) catch {};
            for (messages) |msg| {
                self.memory_manager.addMessage(sid, msg.role, msg.content) catch {};
            }
        }

        const response = agent.run(user_message) catch |err| {
            std.log.err("[{s}] Agent error: {s}", .{ request_id, @errorName(err) });
            self.circuit_brk.recordFailure();
            try self.sendJson(conn, 500, "{\"error\":{\"message\":\"Agent execution failed\"}}", request_id);
            return;
        };
        self.circuit_brk.recordSuccess();
        defer allocator.free(response);

        if (session_id) |sid| {
            self.memory_manager.addMessage(sid, "assistant", response) catch {};
        }

        var json_buf = std.ArrayList(u8).empty;
        defer json_buf.deinit(self.allocator);

        const resp_id = std.fmt.allocPrint(self.allocator, "resp-{s}", .{request_id}) catch "resp-1";
        defer self.allocator.free(resp_id);

        try json_buf.appendSlice(self.allocator, "{\"id\":\"");
        try json_buf.appendSlice(self.allocator, resp_id);
        try json_buf.appendSlice(self.allocator, "\",\"object\":\"response\",\"created_at\":");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &json_buf);
            try allocating.writer.print("{}", .{shared.timestamp()});
            json_buf = allocating.toArrayList();
        }
        try json_buf.appendSlice(self.allocator, ",\"model\":\"");
        try json_buf.appendSlice(self.allocator, self.agent_config.model);
        try json_buf.appendSlice(self.allocator, "\",\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\",\"content\":\"");
            try appendJsonEscaped(&json_buf, self.allocator, response);
        try json_buf.appendSlice(self.allocator, "\"},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":0,\"completion_tokens\":0,\"total_tokens\":0}}");
        try self.sendJson(conn, 200, try json_buf.toOwnedSlice(self.allocator), request_id);
    }
    fn serveStaticFile(self: *Server, conn: std.Io.net.Stream, file_path: []const u8, content_type: []const u8, request_id: []const u8) !void {
        const file = shared.cwdOpenFile(file_path, .{}) catch {
            try self.sendJson(conn, 404, "{\"error\":{\"message\":\"Not found\"}}", request_id);
            return;
        };
        defer file.close(shared.io());
        const stat = file.stat(shared.io()) catch {
            try self.sendJson(conn, 500, "{\"error\":{\"message\":\"Failed to stat file\"}}", request_id);
            return;
        };
        const size = @as(usize, @intCast(stat.size));
        const header = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nX-Request-ID: {s}\r\n\r\n", .{ content_type, size, request_id });
        defer self.allocator.free(header);
        try streamWriteAll(conn, header);
        var buf: [8192]u8 = undefined;
        var total_read: usize = 0;
        while (total_read < size) {
            var iov: [1][]u8 = .{buf[0..]};
            const n = file.readStreaming(shared.io(), &iov) catch |err| switch (err) {
                error.EndOfStream => break,
                else => break,
            };
            if (n == 0) break;
            try streamWriteAll(conn, buf[0..n]);
            total_read += n;
        }
    }

    fn sendOptions(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        const header = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 204 No Content\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\nX-Request-ID: {s}\r\n\r\n", .{request_id});
        defer self.allocator.free(header);
        try streamWriteAll(conn, header);
    }

    fn sendJson(self: *Server, conn: std.Io.net.Stream, status: u16, json: []const u8, request_id: []const u8) !void {
        const header = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 {d} OK\r\nContent-Type: application/json\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nX-Request-ID: {s}\r\n\r\n", .{ status, json.len, request_id });
        defer self.allocator.free(header);
        try streamWriteAll(conn, header);
        try streamWriteAll(conn, json);
    }


    fn handleHealth(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        const uptime = shared.timestamp() - self.start_time;
        const provider = self.agent_config.provider.name();
        const model = self.agent_config.model;
        const tool_count = self.registry.count();
        const response = try std.fmt.allocPrint(self.allocator,
            \\{{"status":"ok","service":"knot3bot","version":"0.1.0","uptime_seconds":{d},"provider":"{s}","model":"{s}","tools":{d},"request_id":"{s}"}}
        , .{ uptime, provider, model, tool_count, request_id });
        defer self.allocator.free(response);
        try self.sendJson(conn, 200, response, request_id);
    }

    fn handleReady(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        // Deep health check - verify DB connectivity
        var db_healthy = true;
        if (self.db_path) |path| {
            _ = SqliteMemorySystem.init(self.allocator, path) catch {
                db_healthy = false;
            };
        }

        const provider = self.agent_config.provider.name();
        const response = try std.fmt.allocPrint(self.allocator,
            \\{{"ready":true,"provider":"{s}","database":"{s}"}}
        , .{ provider, if (db_healthy) "ok" else "error" });
        defer self.allocator.free(response);
        try self.sendJson(conn, 200, response, request_id);
    }

    fn handleGetModels(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        const models_list = self.agent_config.provider.models();
        var json_buf = std.ArrayList(u8).empty;
        defer json_buf.deinit(self.allocator);
        try json_buf.appendSlice(self.allocator, "{\"object\":\"list\",\"data\":[");
        const provider_name = self.agent_config.provider.name();
        const timestamp = shared.timestamp();
        for (models_list, 0..) |model, i| {
            if (i > 0) try json_buf.appendSlice(self.allocator, ",");
            try json_buf.appendSlice(self.allocator, "{\"id\":\"");
            try json_buf.appendSlice(self.allocator, model);
            try json_buf.appendSlice(self.allocator, "\",\"object\":\"model\",\"created\":");
            {
                var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &json_buf);
                try allocating.writer.print("{d}", .{timestamp});
                json_buf = allocating.toArrayList();
            }
            try json_buf.appendSlice(self.allocator, ",\"owned_by\":\"");
            try json_buf.appendSlice(self.allocator, provider_name);
            try json_buf.appendSlice(self.allocator, "\"}");
        }
        try json_buf.appendSlice(self.allocator, "]}");
        try self.sendJson(conn, 200, try json_buf.toOwnedSlice(self.allocator), request_id);
    }

    fn handleGetMetrics(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        const uptime = shared.timestamp() - self.start_time;
        const avg_ms = if (self.metrics.total_requests > 0) self.metrics.total_response_time_ms / self.metrics.total_requests else 0;

        // Prometheus exposition format
        var metrics_text = std.ArrayList(u8).empty;
        defer metrics_text.deinit(self.allocator);

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_uptime_seconds Server uptime in seconds\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_uptime_seconds gauge\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_uptime_seconds {d}\n", .{uptime});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_total_requests Total number of HTTP requests\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_total_requests counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_total_requests {d}\n", .{self.metrics.total_requests});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_chat_requests Total chat completion requests\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_chat_requests counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_chat_requests {d}\n", .{self.metrics.chat_requests});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_streaming_requests Total streaming requests\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_streaming_requests counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_streaming_requests {d}\n", .{self.metrics.streaming_requests});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_errors Total HTTP errors\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_errors counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_errors {d}\n", .{self.metrics.error_count});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_request_size_errors Total request size limit errors\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_request_size_errors counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_request_size_errors {d}\n", .{self.metrics.request_size_errors});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_request_duration_ms Average request duration in ms\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_request_duration_ms gauge\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_request_duration_ms {d}\n", .{avg_ms});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_rate_limit_exceeded Total rate limit violations\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_rate_limit_exceeded counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_rate_limit_exceeded {d}\n", .{self.metrics.rate_limit_exceeded});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_circuit_breaker_state Current circuit breaker state (0=closed, 1=open, 2=half_open)\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_circuit_breaker_state gauge\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_circuit_breaker_state {d}\n", .{@intFromEnum(self.circuit_brk.getState())});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_circuit_breaker_trips Total circuit breaker trips\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_circuit_breaker_trips counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_circuit_breaker_trips {d}\n", .{self.circuit_brk.total_trips});
            metrics_text = allocating.toArrayList();
        }

        try metrics_text.appendSlice(self.allocator, "# HELP knot3bot_circuit_breaker_rejections Total requests rejected by circuit breaker\n");
        try metrics_text.appendSlice(self.allocator, "# TYPE knot3bot_circuit_breaker_rejections counter\n");
        {
            var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &metrics_text);
            try allocating.writer.print("knot3bot_circuit_breaker_rejections {d}\n", .{self.metrics.circuit_breaker_rejections});
            metrics_text = allocating.toArrayList();
        }

        try self.sendMetrics(conn, try metrics_text.toOwnedSlice(self.allocator), request_id);
    }

    fn handleGetTools(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        const tools = self.registry.list();
        var json_buf = std.ArrayList(u8).empty;
        defer json_buf.deinit(self.allocator);
        try json_buf.appendSlice(self.allocator, "{\"tools\":[");

        for (tools, 0..) |tool, i| {
            if (i > 0) try json_buf.appendSlice(self.allocator, ",");
            try json_buf.appendSlice(self.allocator, "{\"name\":\"");
            try appendJsonEscaped(&json_buf, self.allocator, tool.spec.name);
            try json_buf.appendSlice(self.allocator, "\",\"description\":\"");
            try appendJsonEscaped(&json_buf, self.allocator, tool.spec.description);
            try json_buf.appendSlice(self.allocator, "\",\"parameters\":");
            try json_buf.appendSlice(self.allocator, tool.spec.parameters_json);
            try json_buf.appendSlice(self.allocator, "}");
        }

        try json_buf.appendSlice(self.allocator, "]}");
        try self.sendJson(conn, 200, try json_buf.toOwnedSlice(self.allocator), request_id);
    }


    fn handleGetConfig(self: *Server, conn: std.Io.net.Stream, request_id: []const u8) !void {
        const uptime = shared.timestamp() - self.start_time;
        const avg_ms = if (self.metrics.total_requests > 0) self.metrics.total_response_time_ms / self.metrics.total_requests else 0;
        const response = try std.fmt.allocPrint(self.allocator,
            \\{{"provider":"{s}","model":"{s}","version":"0.1.0","uptime_seconds":{d},"total_requests":{d},"avg_response_ms":{d},"rate_limit_exceeded":{d},"max_request_size":{d},"session_id":"default"}}
        , .{ self.agent_config.provider.name(), self.agent_config.model, uptime, self.metrics.total_requests, avg_ms, self.metrics.rate_limit_exceeded, self.config.max_request_size });
        defer self.allocator.free(response);
        try self.sendJson(conn, 200, response, request_id);
    }

    fn sendMetrics(self: *Server, conn: std.Io.net.Stream, metrics: []const u8, request_id: []const u8) !void {
        const header = try std.fmt.allocPrint(self.allocator, "HTTP/1.1 200 OK\r\nContent-Type: text/plain; version=0.0.4\r\nContent-Length: {d}\r\nAccess-Control-Allow-Origin: *\r\nX-Request-ID: {s}\r\n\r\n", .{ metrics.len, request_id });
        defer self.allocator.free(header);
        try streamWriteAll(conn, header);
        try streamWriteAll(conn, metrics);
    }
};

// ============================================================================
// ============================================================================
// Input Validation
// ============================================================================

fn validateChatRequest(req: *const ChatCompletionRequest) bool {
    // Validate model if provided
    if (req.model) |model| {
        if (model.len == 0) return false;
    }

    // Validate messages
    for (req.messages) |msg| {
        // Role must be one of the valid OpenAI roles
        const valid_roles = [_][]const u8{ "system", "user", "assistant", "tool", "developer" };
        var valid_role = false;
        for (valid_roles) |role| {
            if (std.mem.eql(u8, msg.role, role)) {
                valid_role = true;
                break;
            }
        }
        if (!valid_role) return false;

        // Content must not be empty
        if (msg.content.len == 0) return false;
    }

    // Validate temperature range
    if (req.temperature) |t| {
        if (t < 0.0 or t > 2.0) return false;
    }

    // Validate max_tokens is positive
    if (req.max_tokens) |m| {
        if (m == 0) return false;
    }

    return true;
}

// Request/Response Types
// ============================================================================

const ChatCompletionRequest = struct {
    model: ?[]const u8 = null,
    messages: []ChatMessage = &.{},
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: ?bool = null,
    session_id: ?[]const u8 = null,
};

const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
};

test "validateChatRequest - accepts valid request" {
    const messages = &[_]ChatMessage{
        .{ .role = "user", .content = "Hello" },
    };
    const req = ChatCompletionRequest{
        .model = "gpt-4",
        .messages = messages,
        .temperature = 0.7,
        .max_tokens = 100,
    };
    try std.testing.expect(validateChatRequest(&req));
}

test "validateChatRequest - rejects invalid role" {
    const messages = &[_]ChatMessage{
        .{ .role = "invalid", .content = "Hello" },
    };
    const req = ChatCompletionRequest{ .messages = messages };
    try std.testing.expect(!validateChatRequest(&req));
}

test "validateChatRequest - rejects empty content" {
    const messages = &[_]ChatMessage{
        .{ .role = "user", .content = "" },
    };
    const req = ChatCompletionRequest{ .messages = messages };
    try std.testing.expect(!validateChatRequest(&req));
}

test "validateChatRequest - rejects out of range temperature" {
    const messages = &[_]ChatMessage{
        .{ .role = "user", .content = "Hello" },
    };
    const req = ChatCompletionRequest{
        .messages = messages,
        .temperature = 3.0,
    };
    try std.testing.expect(!validateChatRequest(&req));
}

test "validateChatRequest - rejects zero max_tokens" {
    const messages = &[_]ChatMessage{
        .{ .role = "user", .content = "Hello" },
    };
    const req = ChatCompletionRequest{
        .messages = messages,
        .max_tokens = 0,
    };
    try std.testing.expect(!validateChatRequest(&req));
}
