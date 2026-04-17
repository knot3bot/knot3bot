const std = @import("std");
const shared = @import("../shared/root.zig");

/// Escape special characters for JSON string values
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

/// Chat message structure
pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    name: ?[]const u8 = null,
};

/// Tool call function definition
pub const FunctionDef = struct {
    name: []const u8,
    description: ?[]const u8 = null,
    parameters: ?[]const u8 = null,
};

/// Tool definition for function calling
pub const ToolDef = struct {
    type: []const u8 = "function",
    function: FunctionDef,
};

/// OpenAI-compatible Chat Completion Request
pub const ChatRequest = struct {
    model: []const u8,
    messages: []ChatMessage,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    top_p: ?f32 = null,
    stream: bool = false,
    stop: ?[]const u8 = null,
    tools: ?[]ToolDef = null,
    tool_choice: ?[]const u8 = null,

    pub fn toJson(self: *const ChatRequest, allocator: std.mem.Allocator) ![]u8 {
        var json: std.ArrayList(u8) = .empty;
        defer json.deinit(allocator);
        const writer = json.writer(allocator);

        try writer.print("{{\"model\":\"{s}\",\"messages\":[", .{self.model});

        for (self.messages, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.writeAll("{\"role\":\"");
            try writer.writeAll(msg.role);
            try writer.writeAll("\",\"content\":\"");
            try escapeJsonString(writer, msg.content);
            try writer.writeAll("\"}");
        }

        try writer.writeAll("]");

        if (self.stream) {
            try writer.writeAll(",\"stream\":true");
        }

        if (self.temperature) |t| {
            try writer.print(",\"temperature\":{d}", .{t});
        }

        if (self.max_tokens) |m| {
            try writer.print(",\"max_tokens\":{d}", .{m});
        }

        if (self.top_p) |p| {
            try writer.print(",\"top_p\":{d}", .{p});
        }

        if (self.stop) |s| {
            try writer.print(",\"stop\":\"{s}\"", .{s});
        }

        // Serialize tools if present
        if (self.tools) |tools| {
            try writer.writeAll(",\"tools\":[");
            for (tools, 0..) |tool, i| {
                if (i > 0) try writer.writeAll(",");
                try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
                try writer.writeAll(tool.function.name);
                try writer.writeAll("\",\"description\":\"");
                if (tool.function.description) |desc| {
                    try escapeJsonString(writer, desc);
                }
                try writer.writeAll("\",\"parameters\":");
                if (tool.function.parameters) |params| {
                    try writer.writeAll(params);
                } else {
                    try writer.writeAll("{\"type\":\"object\"}");
                }
                try writer.writeAll("}}");
            }
            try writer.writeAll("]");
        }

        // Serialize tool_choice if present
        if (self.tool_choice) |tc| {
            try writer.print(",\"tool_choice\":\"{s}\"", .{tc});
        }

        try writer.writeAll("}");
        return try json.toOwnedSlice(allocator);
    }
};

/// OpenAI-compatible Chat Completion Response
pub const ChatResponse = struct {
    id: []const u8,
    object: []const u8,
    created: u64,
    model: []const u8,
    choices: []Choice,
    usage: ?Usage = null,

    pub const Choice = struct {
        index: u32,
        message: ?ChatMessage,
        delta: ?Delta,
        finish_reason: ?[]const u8,
        tool_calls: ?[]ToolCall = null,

        pub const Delta = struct {
            role: ?[]const u8 = null,
            content: ?[]const u8 = null,
            tool_calls: ?[]ToolCall = null,
        };
    };

    /// Represents a function call in the response
    pub const ToolCall = struct {
        id: []const u8,
        type: []const u8 = "function",
        function: Function,

        pub const Function = struct {
            name: []const u8,
            arguments: []const u8,
        };
    };

    pub const Usage = struct {
        prompt_tokens: u32,
        completion_tokens: u32,
        total_tokens: u32,
    };

    pub fn getContent(self: *const ChatResponse) ?[]const u8 {
        if (self.choices.len > 0) {
            if (self.choices[0].message) |msg| {
                return msg.content;
            }
            if (self.choices[0].delta) |delta| {
                return delta.content;
            }
        }
        return null;
    }

    /// Get tool calls from the response (native function calling)
    pub fn getToolCalls(self: *const ChatResponse) ?[]const ToolCall {
        if (self.choices.len > 0) {
            return self.choices[0].tool_calls;
        }
        return null;
    }

    /// Get finish reason (stop, tool_calls, length, etc.)
    pub fn getFinishReason(self: *const ChatResponse) ?[]const u8 {
        if (self.choices.len > 0) {
            return self.choices[0].finish_reason;
        }
        return null;
    }
};

/// LLM Provider enum with base URLs and default models
pub const Provider = enum {
    openai,
    anthropic,
    kimi,
    minimax,
    zai,
    bailian,
    volcano,
    kimi_plan,
    minimax_plan,
    bailian_plan,
    volcano_plan,
    tencent,
    tencent_plan,
    pub fn baseUrl(self: Provider) []const u8 {
        return switch (self) {
            .openai => "https://api.openai.com/v1",
            .anthropic => "https://api.anthropic.com/v1",
            .kimi, .kimi_plan => "https://api.kimi.com/coding/v1",
            .minimax, .minimax_plan => "https://api.minimaxi.com/v1",
            .zai => "https://api.zplus.ai/v1",
            .bailian, .bailian_plan => "https://dashscope.aliyuncs.com/compatible-mode/v1",
            .volcano => "https://ark.cn-beijing.volces.com/api/v3",
            .volcano_plan => "https://ark.cn-beijing.volces.com/api/coding/v3",
            .tencent, .tencent_plan => "https://api.hunyuan.cloud.tencent.com/v1",
        };
    }

    pub fn defaultModel(self: Provider) []const u8 {
        return switch (self) {
            .openai => "gpt-4o",
            .anthropic => "claude-3-5-sonnet-20240620",
            .kimi, .kimi_plan => "kimi-k2.5",
            .minimax, .minimax_plan => "MiniMax-M2.7",
            .zai => "glm-4.7",
            .bailian, .bailian_plan => "qwen3.5-plus",
            .volcano => "doubao-seed-1-8-251228",
            .volcano_plan => "ark-code-latest",
            .tencent, .tencent_plan => "hunyuan-lite",
        };
    }


    pub fn name(self: Provider) []const u8 {
        return switch (self) {
            .openai => "OpenAI",
            .anthropic => "Anthropic",
            .kimi => "Kimi (Moonshot)",
            .kimi_plan => "Kimi Coding Plan",
            .minimax => "MiniMax",
            .minimax_plan => "MiniMax Coding Plan",
            .zai => "Z.ai (Zhipu)",
            .bailian => "Bailian (Alibaba)",
            .bailian_plan => "Bailian Coding Plan",
            .volcano => "Volcano Engine",
            .volcano_plan => "Volcano Engine Coding Plan",
            .tencent => "Tencent (Hunyuan)",
            .tencent_plan => "Tencent Coding Plan",
        };
    }
    pub fn internalName(self: Provider) []const u8 {
        return switch (self) {
            .openai => "openai",
            .anthropic => "anthropic",
            .kimi => "kimi",
            .kimi_plan => "kimi-plan",
            .minimax => "minimax",
            .minimax_plan => "minimax-plan",
            .zai => "zai",
            .bailian => "bailian",
            .bailian_plan => "bailian-plan",
            .volcano => "volcano",
            .volcano_plan => "volcano-plan",
            .tencent => "tencent",
            .tencent_plan => "tencent-plan",
        };
    }
    pub fn models(self: Provider) []const []const u8 {
        return switch (self) {
            .openai => &.{ "gpt-4o", "gpt-4o-mini", "gpt-4-turbo", "gpt-4", "gpt-3.5-turbo" },
            .anthropic => &.{ "claude-3-5-sonnet-20240620", "claude-3-opus-20240229", "claude-3-sonnet-20240229", "claude-3-haiku-20240307" },
            .kimi, .kimi_plan => &.{ "kimi-k2.5", "kimi-k2-turbo-preview", "moonshot-v1-8k", "moonshot-v1-32k", "moonshot-v1-128k", "moonshot-v1-auto" },
            .minimax, .minimax_plan => &.{ "MiniMax-M2.7", "MiniMax-M2.5", "MiniMax-M2.1", "MiniMax-M2", "abab6.5s-chat" },
            .zai => &.{ "glm-4.7", "glm-4.7-flash", "glm-4.6", "glm-4-plus", "glm-4-flash" },
            .bailian, .bailian_plan => &.{ "qwen3.5-plus", "qwen3.5-flash", "qwen3-max", "qwen-plus", "qwen-flash" },
            .volcano => &.{ "doubao-seed-1-8-251228", "doubao-pro-32k", "doubao-pro-128k", "doubao-lite-32k", "doubao-seed-1-6-250615" },
            .volcano_plan => &.{ "ark-code-latest", "doubao-seed-code", "glm-4.7", "kimi-k2-thinking", "doubao-seed-code-preview-251028" },
            .tencent, .tencent_plan => &.{ "hunyuan-lite", "hunyuan-standard", "hunyuan-pro", "hunyuan-t1" },
        };
    }
    pub fn fromStr(s: []const u8) ?Provider {
        const lowered = std.ascii.allocLowerString(std.heap.page_allocator, s) catch return null;
        defer std.heap.page_allocator.free(lowered);
        inline for (.{
            .{ "openai", .openai },
            .{ "anthropic", .anthropic },
            .{ "claude", .anthropic },
            .{ "gpt", .openai },
            .{ "kimi-plan", .kimi_plan },
            .{ "kimi", .kimi },
            .{ "moonshot", .kimi },
            .{ "minimax-plan", .minimax_plan },
            .{ "minimax", .minimax },
            .{ "zai", .zai },
            .{ "zhipu", .zai },
            .{ "glm", .zai },
            .{ "bailian-plan", .bailian_plan },
            .{ "bailian", .bailian },
            .{ "qwen", .bailian },
            .{ "aliyun", .bailian },
            .{ "alibaba", .bailian },
            .{ "volcano-plan", .volcano_plan },
            .{ "volcano", .volcano },
            .{ "byte", .volcano },
            .{ "doubao", .volcano },
            .{ "火山", .volcano },
            .{ "tencent-plan", .tencent_plan },
            .{ "tencent", .tencent },
            .{ "hunyuan", .tencent },
            .{ "腾讯", .tencent },
        }) |pair| {
            if (std.mem.eql(u8, lowered, pair[0])) {
                return pair[1];
            }
        }
        return null;
    }
};

/// Stream callback type for receiving chunks
pub const StreamCallback = *const fn (chunk: []const u8, user_data: ?*anyopaque) void;

/// OpenAI-compatible API client using curl subprocess
pub const LLMClient = struct {
    allocator: std.mem.Allocator,
    provider: Provider,
    api_key: []const u8,
    base_url: []const u8,
    model: []const u8,
    timeout_seconds: u32 = 120,

    pub fn init(allocator: std.mem.Allocator, api_key: []const u8, provider: Provider, model: []const u8) LLMClient {
        const actual_model = if (model.len > 0) model else provider.defaultModel();
        return .{
            .allocator = allocator,
            .provider = provider,
            .api_key = api_key,
            .base_url = provider.baseUrl(),
            .model = actual_model,
            .timeout_seconds = 120,
        };
    }

    pub fn deinit(self: *LLMClient) void {
        _ = self;
    }

    fn buildRequestBody(self: *LLMClient, messages: []const ChatMessage) ![]u8 {
        var body: std.ArrayList(u8) = .empty;

        try body.appendSlice(self.allocator, "{\"model\":\"");
        try body.appendSlice(self.allocator, self.model);
        try body.appendSlice(self.allocator, "\",\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try body.appendSlice(self.allocator, ",");
            try body.appendSlice(self.allocator, "{\"role\":\"");
            try body.appendSlice(self.allocator, msg.role);
            try body.appendSlice(self.allocator, "\",\"content\":\"");
            for (msg.content) |c| {
                switch (c) {
                    '"' => try body.appendSlice(self.allocator, "\\\""),
                    '\\' => try body.appendSlice(self.allocator, "\\\\"),
                    '\n' => try body.appendSlice(self.allocator, "\\n"),
                    '\r' => try body.appendSlice(self.allocator, "\\r"),
                    '\t' => try body.appendSlice(self.allocator, "\\t"),
                    else => try body.append(self.allocator, c),
                }
            }
            try body.appendSlice(self.allocator, "\"}");
        }

        try body.appendSlice(self.allocator, "]}");
        return body.toOwnedSlice(self.allocator);
    }

    fn buildStreamRequestBody(self: *LLMClient, messages: []const ChatMessage) ![]u8 {
        var body: std.ArrayList(u8) = .empty;

        try body.appendSlice(self.allocator, "{\"model\":\"");
        try body.appendSlice(self.allocator, self.model);
        try body.appendSlice(self.allocator, "\",\"stream\":true,\"messages\":[");

        for (messages, 0..) |msg, i| {
            if (i > 0) try body.appendSlice(self.allocator, ",");
            try body.appendSlice(self.allocator, "{\"role\":\"");
            try body.appendSlice(self.allocator, msg.role);
            try body.appendSlice(self.allocator, "\",\"content\":\"");
            for (msg.content) |c| {
                switch (c) {
                    '"' => try body.appendSlice(self.allocator, "\\\""),
                    '\\' => try body.appendSlice(self.allocator, "\\\\"),
                    '\n' => try body.appendSlice(self.allocator, "\\n"),
                    '\r' => try body.appendSlice(self.allocator, "\\r"),
                    '\t' => try body.appendSlice(self.allocator, "\\t"),
                    else => try body.append(self.allocator, c),
                }
            }
            try body.appendSlice(self.allocator, "\"}");
        }

        try body.appendSlice(self.allocator, "]}");
        return body.toOwnedSlice(self.allocator);
    }

    fn extractContent(self: *LLMClient, response_body: []const u8) ![]const u8 {
        if (std.mem.indexOf(u8, response_body, "\"error\"")) |_| {
            return try std.fmt.allocPrint(self.allocator, "API Error: {s}", .{response_body});
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response_body, .{}) catch {
            return try self.allocator.dupe(u8, response_body);
        };
        defer parsed.deinit();

        const root = parsed.value;

        if (root.object.get("choices")) |choices| {
            if (choices.array.items.len > 0) {
                const first_choice = choices.array.items[0];

                if (first_choice.object.get("message")) |message| {
                    if (message.object.get("content")) |content| {
                        if (content.string.len > 0) {
                            return try self.allocator.dupe(u8, content.string);
                        }
                    }
                }

                if (first_choice.object.get("delta")) |delta| {
                    if (delta.object.get("content")) |content| {
                        if (content.string.len > 0) {
                            return try self.allocator.dupe(u8, content.string);
                        }
                    }
                }

                if (first_choice.object.get("text")) |text| {
                    if (text.string.len > 0) {
                        return try self.allocator.dupe(u8, text.string);
                    }
                }
            }
        }

        if (root.object.get("output")) |output| {
            if (output.object.get("text")) |text| {
                if (text.string.len > 0) {
                    return try self.allocator.dupe(u8, text.string);
                }
            }
        }

        if (root.object.get("data")) |data| {
            if (data.array.items.len > 0) {
                const first = data.array.items[0];
                if (first.object.get("content")) |content| {
                    if (content.string.len > 0) {
                        return try self.allocator.dupe(u8, content.string);
                    }
                }
            }
        }

        return try self.allocator.dupe(u8, response_body);
    }

    fn extractStreamContent(self: *LLMClient, data: []const u8) ?[]const u8 {
        const content_key = "\"content\":\"";
        if (std.mem.indexOf(u8, data, content_key)) |idx| {
            const start = idx + content_key.len;
            var i: usize = start;
            var end: usize = start;
            while (i < data.len) {
                if (data[i] == '\\' and i + 1 < data.len) {
                    i += 2;
                } else if (data[i] == '"') {
                    end = i;
                    break;
                } else {
                    i += 1;
                }
            }
            if (end > start) {
                const slice = data[start..end];
                var result: std.ArrayList(u8) = .empty;

                var j: usize = 0;
                while (j < slice.len) {
                    if (slice[j] == '\\' and j + 1 < slice.len) {
                        switch (slice[j + 1]) {
                            'n' => result.append(self.allocator, '\n') catch {},
                            'r' => result.append(self.allocator, '\r') catch {},
                            't' => result.append(self.allocator, '\t') catch {},
                            '"' => result.append(self.allocator, '"') catch {},
                            '\\' => result.append(self.allocator, '\\') catch {},
                            else => result.append(self.allocator, slice[j + 1]) catch {},
                        }
                        j += 2;
                    } else {
                        result.append(self.allocator, slice[j]) catch {};
                        j += 1;
                    }
                }

                if (result.items.len > 0) {
                    return result.toOwnedSlice(self.allocator) catch return null;
                }
            }
        }
        return null;
    }

    pub fn chatStream(self: *LLMClient, messages: []const ChatMessage, callback: StreamCallback, user_data: ?*anyopaque) !void {
        const body = try self.buildStreamRequestBody(messages);
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const argv = &[_][]const u8{
            "curl",
            "-s",
            "--no-buffer",
            "--keepalive-time",
            "30",
            "--keepalive",
            "--tcp-fastopen",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            auth_header,
            "--data-binary",
            "@-",
            url,
            "--data-binary",
            "@-",
            url,
        };

        const io = shared.context.io();
        var child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        });

        if (child.stdin) |stdin_file| {
            stdin_file.writeStreamingAll(io, body) catch {
                stdin_file.close(io);
                child.stdin = null;
                child.kill(io);
                _ = child.wait(io) catch {};
                return error.CurlWriteError;
            };
            stdin_file.close(io);
            child.stdin = null;
        } else {
            child.kill(io);
            _ = child.wait(io) catch {};
            return error.CurlSpawnError;
        }
        const stdout_file = child.stdout.?;
        var response_buffer: [8192]u8 = undefined;
        var line_buffer: [4096]u8 = undefined;
        var line_pos: usize = 0;

        while (true) {
            const bytes_read = stdout_file.readStreaming(io, &[_][]u8{&response_buffer}) catch |err| {
                std.log.err("Read error: {s}", .{@errorName(err)});
                break;
            };

            if (bytes_read == 0) break;

            for (response_buffer[0..bytes_read]) |byte| {
                if (byte == '\n') {
                    if (line_pos > 0) {
                        const line = line_buffer[0..line_pos];

                        if (std.mem.startsWith(u8, line, "data: ")) {
                            const data = line[6..];

                            if (std.mem.eql(u8, data, "[DONE]")) {
                                stdout_file.close(io);
                                child.stdout = null;
                                _ = child.wait(io) catch {};
                                return;
                            }

                            if (self.extractStreamContent(data)) |content| {
                                if (content.len > 0) {
                                    callback(content, user_data);
                                }
                            }
                        }
                        line_pos = 0;
                    }
                } else if (line_pos < line_buffer.len) {
                    line_buffer[line_pos] = byte;
                    line_pos += 1;
                }
            }
        }

        stdout_file.close(io);
        child.stdout = null;
        _ = child.wait(io) catch {};
    }

    pub fn chat(self: *LLMClient, messages: []const ChatMessage) ![]const u8 {
        const body = try self.buildRequestBody(messages);
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const temp_path = "/tmp/knot3bot_curl_body.json";
        try shared.context.cwdWriteFile(temp_path, body);
        defer shared.context.cwdDeleteFile(temp_path) catch {};

        const data_arg = try std.fmt.allocPrint(self.allocator, "@{s}", .{temp_path});
        defer self.allocator.free(data_arg);

        const argv = &[_][]const u8{
            "curl",
            "-s",
            "--max-time",
            "120",
            "--keepalive-time",
            "30",
            "--keepalive",
            "--tcp-fastopen",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            auth_header,
            "--data-binary",
            data_arg,
            url,
        };

        const result = std.process.run(self.allocator, shared.context.io(), .{
            .argv = argv,
        }) catch |err| {
            std.log.warn("curl run failed: {s}", .{@errorName(err)});
            return error.CurlSpawnError;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    return switch (code) {
                        6 => error.CurlDnsError,
                        7 => error.CurlConnectError,
                        28 => error.CurlTimeout,
                        35, 51, 58, 60 => error.CurlTlsError,
                        else => error.CurlFailed,
                    };
                }
            },
            else => return error.CurlFailed,
        }

        return try self.extractContent(result.stdout);
    }
    /// Chat with tools (function calling API)
    pub fn chatWithTools(self: *LLMClient, messages: []const ChatMessage, tools: []const ToolDef) ![]const u8 {
        // Mock mode - return fake response for UI testing
        if (std.mem.eql(u8, self.api_key, "mock")) {
            const last_msg = if (messages.len > 0) messages[messages.len - 1].content else "hello";
            var response = std.ArrayList(u8).empty;
            try response.appendSlice(self.allocator, "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"Mock: ");
            try response.appendSlice(self.allocator, last_msg);
            try response.appendSlice(self.allocator, "\"}}]}");
            return response.toOwnedSlice(self.allocator);
        }

        // Build request with tools
        var body_list: std.ArrayList(u8) = .empty;
        defer body_list.deinit(self.allocator);
        var allocating = std.Io.Writer.Allocating.fromArrayList(self.allocator, &body_list);
        const writer = &allocating.writer;
        // Start with model
        try writer.writeAll("{\"model\":\"");
        try writer.writeAll(self.model);
        try writer.writeAll("\",\"messages\":[");
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
            try writer.writeAll("{\"type\":\"function\",\"function\":{\"name\":\"");
            try writer.writeAll(tool.function.name);
            try writer.writeAll("\",\"description\":\"");
            if (tool.function.description) |desc| {
                try escapeJsonString(writer, desc);
            }
            try writer.writeAll("\",\"parameters\":");
            if (tool.function.parameters) |params| {
                // Parse and verify the JSON string, then write raw
                if (std.json.parseFromSlice(std.json.Value, self.allocator, params, .{})) |_| {
                    try writer.writeAll(params);
                } else |_| {
                    try writer.writeAll("{\"type\":\"object\"}");
                }
            } else {
                try writer.writeAll("{\"type\":\"object\"}");
            }
            try writer.writeAll("}}");
        }
        try writer.writeAll("]}");
        body_list = allocating.toArrayList();
        const body = try body_list.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/chat/completions", .{self.base_url});
        defer self.allocator.free(url);

        const auth_header = try std.fmt.allocPrint(self.allocator, "Authorization: Bearer {s}", .{self.api_key});
        defer self.allocator.free(auth_header);

        const temp_path = "/tmp/knot3bot_curl_body.json";
        try shared.context.cwdWriteFile(temp_path, body);
        defer shared.context.cwdDeleteFile(temp_path) catch {};

        const data_arg = try std.fmt.allocPrint(self.allocator, "@{s}", .{temp_path});
        defer self.allocator.free(data_arg);

        const argv = &[_][]const u8{
            "curl",
            "-s",
            "--max-time",
            "120",
            "--keepalive-time",
            "30",
            "--keepalive",
            "--tcp-fastopen",
            "-X",
            "POST",
            "-H",
            "Content-Type: application/json",
            "-H",
            auth_header,
            "--data-binary",
            data_arg,
            url,
        };

        const result = std.process.run(self.allocator, shared.context.io(), .{
            .argv = argv,
        }) catch |err| {
            std.log.warn("curl run failed: {s}", .{@errorName(err)});
            return error.CurlSpawnError;
        };
        defer self.allocator.free(result.stdout);
        defer self.allocator.free(result.stderr);

        switch (result.term) {
            .exited => |code| {
                if (code != 0) {
                    return switch (code) {
                        6 => error.CurlDnsError,
                        7 => error.CurlConnectError,
                        28 => error.CurlTimeout,
                        else => error.CurlFailed,
                    };
                }
            },
            else => return error.CurlFailed,
        }

        return try self.extractContent(result.stdout);
    }
};

/// Retry configuration for API calls
pub const RetryConfig = struct {
    max_retries: u3 = 3,
    initial_delay_ms: u32 = 1000,
    max_delay_ms: u32 = 30000,
    backoff_multiplier: f32 = 2.0,
};

/// Cost estimation for different models (per 1M tokens)
pub const ModelCost = struct {
    input_cost: f64,
    output_cost: f64,
};

/// Default costs (can be overridden per provider)
pub const default_costs: []const ModelCost = &.{
    // Index 0: GPT-4
    .{ .input_cost = 30.0, .output_cost = 60.0 },
    // Index 1: GPT-3.5
    .{ .input_cost = 0.5, .output_cost = 1.5 },
    // Index 2: Claude
    .{ .input_cost = 3.0, .output_cost = 15.0 },
};

/// Usage tracking for cost estimation
pub const UsageTracker = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_requests: u32 = 0,
    failed_requests: u32 = 0,

    pub fn addUsage(self: *UsageTracker, prompt: u32, completion: u32) void {
        self.prompt_tokens += prompt;
        self.completion_tokens += completion;
    }

    pub fn totalTokens(self: *const UsageTracker) u32 {
        return self.prompt_tokens + self.completion_tokens;
    }

    /// Estimate cost in USD (simplified - assumes GPT-4 pricing)
    pub fn estimateCost(self: *const UsageTracker) f64 {
        const input_cost_per_1k = 0.03; // $30/1M
        const output_cost_per_1k = 0.06; // $60/1M
        return (@as(f64, @floatFromInt(self.prompt_tokens)) / 1000.0) * input_cost_per_1k +
            (@as(f64, @floatFromInt(self.completion_tokens)) / 1000.0) * output_cost_per_1k;
    }
};

/// Perform chat with automatic retry and backoff
/// Perform chat with automatic retry and backoff
pub fn chatWithRetry(
    client: *LLMClient,
    messages: []const ChatMessage,
    config: RetryConfig,
) ![]const u8 {
    var delay_ms: u32 = config.initial_delay_ms;
    var last_error: anyerror = error.Unknown;

    for (0..config.max_retries + 1) |attempt| {
        if (attempt > 0) {
            std.debug.print("Retry attempt {d}/{d} after {d}ms delay...\n", .{
                attempt, config.max_retries, delay_ms,
            });
            std.Thread.sleep(delay_ms * std.time.ns_per_ms);
            delay_ms = @min(
                @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay_ms)) * config.backoff_multiplier)),
                config.max_delay_ms,
            );
        }

        const result = client.chat(messages) catch |err| {
            last_error = err;
            const should_retry = switch (err) {
                error.CurlConnectError, error.CurlTimeout, error.CurlReadError, error.CurlWriteError, error.CurlWaitError, error.RateLimited => true,
                else => false,
            };
            if (!should_retry or attempt >= config.max_retries) {
                return err;
            }
            continue;
        };

        // Success
        return result;
    }
    return last_error;
}

/// Perform streaming chat with automatic retry and backoff
pub fn chatStreamWithRetry(
    client: *LLMClient,
    messages: []const ChatMessage,
    config: RetryConfig,
    callback: StreamCallback,
    user_data: ?*anyopaque,
) !void {
    var delay_ms: u32 = config.initial_delay_ms;

    for (0..config.max_retries + 1) |attempt| {
        if (attempt > 0) {
            std.debug.print("Stream retry attempt {d}/{d} after {d}ms delay...\n", .{
                attempt, config.max_retries, delay_ms,
            });
            try std.Io.sleep(shared.context.io(), std.Io.Duration.fromMilliseconds(delay_ms), .real);
            delay_ms = @min(
                @as(u32, @intFromFloat(@as(f32, @floatFromInt(delay_ms)) * config.backoff_multiplier)),
                config.max_delay_ms,
            );
        }

        client.chatStream(messages, callback, user_data) catch |err| {
            const should_retry = switch (err) {
                error.CurlWriteError, error.CurlSpawnError => true,
                else => false,
            };
            if (!should_retry or attempt >= config.max_retries) {
                return err;
            }
            continue;
        };

        // Success
        return;
    }
}

/// Alias for backwards compatibility
pub const OpenAIClient = LLMClient;

test "Provider base URL" {
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1", Provider.kimi.baseUrl());
    try std.testing.expectEqualStrings("https://api.minimax.chat/v1", Provider.minimax.baseUrl());
    try std.testing.expectEqualStrings("https://api.zplus.ai/v1", Provider.zai.baseUrl());
    try std.testing.expectEqualStrings("https://dashscope.aliyuncs.com/compatible-mode/v1", Provider.bailian.baseUrl());
    try std.testing.expectEqualStrings("https://ark.cn-beijing.volces.com/api/v3", Provider.volcano.baseUrl());
}

test "Provider from string" {
    try std.testing.expectEqual(Provider.kimi, Provider.fromStr("kimi").?);
    try std.testing.expectEqual(Provider.minimax, Provider.fromStr("minimax").?);
    try std.testing.expectEqual(Provider.bailian, Provider.fromStr("qwen-plus").?);
    try std.testing.expectEqual(Provider.volcano, Provider.fromStr("doubao").?);
}

test "LLMClient initialization" {
    const allocator = std.testing.allocator;
    var client = LLMClient.init(allocator, "test-key", .kimi, "moonshot-v1-8k");
    defer client.deinit();
    try std.testing.expectEqualStrings("moonshot-v1-8k", client.model);
    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1", client.base_url);
}

test "ChatRequest toJson" {
    const allocator = std.testing.allocator;
    const messages = &[_]ChatMessage{
        .{ .role = "user", .content = "Hello" },
    };
    const req = ChatRequest{
        .model = "gpt-4",
        .messages = messages,
        .temperature = 0.7,
    };
    const json = try req.toJson(allocator);
    defer allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"gpt-4\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"Hello\"") != null);
}
