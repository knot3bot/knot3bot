//! Anthropic API Provider - Minimal text-only adapter
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

        const auth_header = try std.fmt.allocPrint(self.allocator, "x-api-key: {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

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
            auth_header,
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

        const auth_header = try std.fmt.allocPrint(self.allocator, "x-api-key: {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

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
            auth_header,
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
            try escapeJsonString(writer, msg.content);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("],\"tools\":[");
        for (tools, 0..) |tool, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"name\":\"");
            try escapeJsonString(writer, tool.name);
            try writer.writeAll("\",\"description\":\"");
            if (tool.description) |d| try escapeJsonString(writer, d);
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

    fn convertToOpenAIFormat(self: *AnthropicClient, response_body: []const u8) ![]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch {
            return try std.fmt.allocPrint(self.allocator, "{{\"choices\":[]}}", .{});
        };
        defer parsed.deinit();

        const root_val = parsed.value;
        if (root_val != .object) return try std.fmt.allocPrint(self.allocator, "{{\"choices\":[]}}", .{});

        var text_parts = std.ArrayList(u8).empty;
        defer text_parts.deinit(self.allocator);
        var has_tool_calls = false;

        var output_json = std.ArrayList(u8).empty;
        defer output_json.deinit(self.allocator);
        var output_allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &output_json);
        var w = output_allocating.writer;

        try w.writeAll("{\"choices\":[{\"index\":0,\"message\":{\"role\":\"assistant\"");

        if (root_val.object.get("content")) |content| {
            if (content == .array) {
                for (content.array.items) |block| {
                    if (block == .object) {
                        const btype = if (block.object.get("type")) |t| if (t == .string) t.string else "" else "";
                        if (std.mem.eql(u8, btype, "text")) {
                            if (block.object.get("text")) |t| {
                                if (t == .string) {
                                    if (text_parts.items.len > 0) try text_parts.appendSlice(self.allocator, " ");
                                    try text_parts.appendSlice(self.allocator, t.string);
                                }
                            }
                        } else if (std.mem.eql(u8, btype, "tool_use")) {
                            has_tool_calls = true;
                        }
                    }
                }
            }
        }

        try w.writeAll(",\"content\":\"");
        try escapeJsonString(w, text_parts.items);
        try w.writeAll("\"");

        if (has_tool_calls) {
            try w.writeAll(",\"tool_calls\":[");
            var first_tc = true;
            if (root_val.object.get("content")) |content| {
                if (content == .array) {
                    for (content.array.items) |block| {
                        if (block == .object) {
                            const btype = if (block.object.get("type")) |t| if (t == .string) t.string else "" else "";
                            if (std.mem.eql(u8, btype, "tool_use")) {
                                if (!first_tc) try w.writeAll(",");
                                first_tc = false;
                                const tc_id = if (block.object.get("id")) |v| if (v == .string) v.string else "" else "";
                                const tc_name = if (block.object.get("name")) |v| if (v == .string) v.string else "" else "";
                                const tc_input = if (block.object.get("input")) |v| std.json.Stringify.valueAlloc(self.allocator, v, .{}) catch "{}" else "{}";
                                defer if (block.object.get("input")) |_| self.allocator.free(tc_input);
                                try w.print("{{\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"{s}\",\"arguments\":", .{ tc_id, tc_name });
                                try w.writeAll(tc_input);
                                try w.writeAll("}}}");
                            }
                        }
                    }
                }
            }
            try w.writeAll("]");
        }

        try w.writeAll("}}]");

        if (root_val.object.get("usage")) |u| {
            if (u == .object) {
                var prompt_tokens: u32 = 0;
                var completion_tokens: u32 = 0;
                if (u.object.get("input_tokens")) |pt| {
                    if (pt == .integer) prompt_tokens = @intCast(pt.integer);
                }
                if (u.object.get("output_tokens")) |ct| {
                    if (ct == .integer) completion_tokens = @intCast(ct.integer);
                }
                try w.print(",\"usage\":{{\"prompt_tokens\":{d},\"completion_tokens\":{d},\"total_tokens\":{d}}}", .{ prompt_tokens, completion_tokens, prompt_tokens + completion_tokens });
            }
        }

        try w.writeAll("}");
        output_json = output_allocating.toArrayList();
        return try output_json.toOwnedSlice(self.allocator);
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
            try escapeJsonString(writer, msg.content);
            try writer.writeAll("\"}");
        }
        try writer.writeAll("]}");
        json = json_allocating.toArrayList();
        return try json.toOwnedSlice(self.allocator);
    }

    fn extractContent(self: *AnthropicClient, response_body: []const u8) ![]const u8 {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch {
            return try self.allocator.dupe(u8, "Anthropic API error");
        };
        defer parsed.deinit();

        const root_val = parsed.value;
        if (root_val != .object) return try self.allocator.dupe(u8, "Invalid Anthropic response");

        if (root_val.object.get("content")) |content| {
            if (content == .array and content.array.items.len > 0) {
                const first = content.array.items[0];
                if (first == .object) {
                    if (first.object.get("text")) |text| {
                        if (text == .string) return try self.allocator.dupe(u8, text.string);
                    }
                }
            }
        }

        if (root_val.object.get("error")) |err_val| {
            if (err_val == .object) {
                if (err_val.object.get("message")) |msg| {
                    if (msg == .string) return try self.allocator.dupe(u8, msg.string);
                }
            }
        }

        return try self.allocator.dupe(u8, "Empty Anthropic response");
    }
};

fn escapeJsonString(writer_arg: anytype, str: []const u8) !void {
    var writer = writer_arg;
    for (str) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
