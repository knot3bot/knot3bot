//! Anthropic API Provider — text-only adapter using curl subprocess.
//! All API keys are written to temp files (never in argv) to prevent
//! exposure via ps aux / process inspection.

const std = @import("std");
const shared = @import("../shared/root.zig");

pub const AnthropicMessage = struct {
    role: []const u8,
    content: []const u8,
};

pub const ToolDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    input_schema: ?[]const u8 = null,
};

pub const AnthropicClient = struct {
    allocator: std.mem.Allocator,
    api_key: []const u8,
    model: []const u8,

    pub const Error = error{
        OutOfMemory,
        CurlSpawnError,
        CurlWriteError,
        AuthFileWriteError,
    };

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, model: []const u8) AnthropicClient {
        return .{
            .allocator = allocator,
            .api_key = api_key,
            .model = model,
        };
    }

    pub fn deinit(self: *AnthropicClient) void {
        _ = self;
    }

    pub fn chat(self: *AnthropicClient, messages: []const AnthropicMessage) ![]const u8 {
        const body = try self.buildRequestBody(messages);
        defer self.allocator.free(body);

        const auth_file = try writeAuthHeaderFile(self.allocator, self.api_key);
        defer cleanupAuthFile(self.allocator, auth_file);

        const argv = &[_][]const u8{
            "curl",
            "-s",
            "--max-time",
            "120",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            auth_file,
            "-H",
            "anthropic-version: 2023-06-01",
            "--data-binary",
            "@-",
            "https://api.anthropic.com/v1/messages",
        };

        return try self.runCurl(argv, body);
    }

    pub fn chatWithTools(self: *AnthropicClient, messages: []const AnthropicMessage, tools: []const ToolDef) ![]const u8 {
        const body = try self.buildRequestBodyWithTools(messages, tools);
        defer self.allocator.free(body);

        const auth_file = try writeAuthHeaderFile(self.allocator, self.api_key);
        defer cleanupAuthFile(self.allocator, auth_file);

        const argv = &[_][]const u8{
            "curl",
            "-s",
            "--max-time",
            "120",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            auth_file,
            "-H",
            "anthropic-version: 2023-06-01",
            "--data-binary",
            "@-",
            "https://api.anthropic.com/v1/messages",
        };

        return try self.runCurl(argv, body);
    }

    fn runCurl(self: *AnthropicClient, argv: []const []const u8, body: []const u8) ![]u8 {
        const io = shared.context.io();
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });
        defer {
            child.kill(io);
            _ = child.wait(io) catch {};
        }

        if (child.stdin) |stdin_file| {
            stdin_file.writeStreamingAll(io, body) catch {
                stdin_file.close(io);
                child.stdin = null;
                return error.CurlWriteError;
            };
            stdin_file.close(io);
            child.stdin = null;
        } else {
            return error.CurlSpawnError;
        }

        const stdout_file = child.stdout.?;
        defer stdout_file.close(io);

        var result = std.ArrayList(u8).empty;
        defer result.deinit(self.allocator);

        var buf: [8192]u8 = undefined;
        var file_reader = std.Io.File.reader(stdout_file, io, &buf);
        while (true) {
            const n = file_reader.interface.readSliceShort(&buf) catch break;
            if (n == 0) break;
            try result.appendSlice(self.allocator, buf[0..n]);
        }

        return try result.toOwnedSlice(self.allocator);
    }

    fn buildRequestBodyWithTools(self: *AnthropicClient, messages: []const AnthropicMessage, tools: []const ToolDef) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        var json_allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &json);
        var writer = json_allocating.writer;

        try writer.print("{{\"model\":\"{s}\",\"max_tokens\":1024,\"messages\":[", .{self.model});
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":\"");
            try writer.writeAll(msg.role);
            try writer.writeAll("\",\"content\":\"");
            try shared.json.writeJsonEscaped(writer, msg.content);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("],\"tools\":[");
        for (tools, 0..) |tool, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":\"");
            try shared.json.writeJsonEscaped(writer, tool.name);
            try writer.writeAll("\",\"description\":\"");
            if (tool.description) |d| try shared.json.writeJsonEscaped(writer, d);
            try writer.writeAll("\",\"input_schema\":");
            if (tool.input_schema) |s| {
                try writer.writeAll(s);
            } else {
                try writer.writeAll("{}");
            }
            try writer.writeAll("}");
        }
        try writer.writeAll("]}");
        json = json_allocating.toArrayList();
        return try json.toOwnedSlice(self.allocator);
    }

    fn buildRequestBody(self: *AnthropicClient, messages: []const AnthropicMessage) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(self.allocator);
        var json_allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &json);
        var writer = json_allocating.writer;

        try writer.print("{{\"model\":\"{s}\",\"max_tokens\":1024,\"messages\":[", .{self.model});
        for (messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":\"");
            try writer.writeAll(msg.role);
            try writer.writeAll("\",\"content\":\"");
            try shared.json.writeJsonEscaped(writer, msg.content);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("]}");
        json = json_allocating.toArrayList();
        return try json.toOwnedSlice(self.allocator);
    }
};

// ── file-scoped helpers ────────────────────────────────────────────

/// Atomic counter for unique temp file names, avoiding collisions.
var temp_file_counter: std.atomic.Value(u64) = std.atomic.Value(u64).init(0);

/// Write auth header to a temp file so API key is NOT visible in ps aux.
/// Uses curl @file syntax: -H @/tmp/knot3bot_auth_XXXXXX
/// Caller must call cleanupAuthFile after curl exits.
fn writeAuthHeaderFile(allocator: std.mem.Allocator, api_key: []const u8) ![]const u8 {
    const seed = temp_file_counter.fetchAdd(1, .monotonic);
    const path = try std.fmt.allocPrint(allocator, "/tmp/knot3bot_auth_{x}", .{seed});
    errdefer allocator.free(path);

    const content = try std.fmt.allocPrint(allocator, "x-api-key: {s}", .{api_key});
    defer allocator.free(content);

    shared.context.cwdWriteFile(path, content) catch return error.AuthFileWriteError;
    return path;
}

/// Remove auth header temp file and free its path string.
/// Safe to call even if path is empty (no-op).
fn cleanupAuthFile(allocator: std.mem.Allocator, path: []const u8) void {
    if (path.len > 0) {
        shared.context.cwdDeleteFile(path) catch {};
        allocator.free(path);
    }
}
