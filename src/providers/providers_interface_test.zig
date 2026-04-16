//! Provider interface tests - ChatRequest, ChatResponse, LLMClient
//!
//! Tests for request/response parsing and client initialization.
const std = @import("std");
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ChatRequest = providers.ChatRequest;
const ChatResponse = providers.ChatResponse;
const ToolDef = providers.ToolDef;
const FunctionDef = providers.FunctionDef;
const LLMClient = providers.LLMClient;

// ============================================================================
// ChatMessage Tests
// ============================================================================

test "ChatMessage - creates valid message" {
    const msg = ChatMessage{
        .role = "user",
        .content = "Hello, world!",
    };
    try std.testing.expectEqualStrings("user", msg.role);
    try std.testing.expectEqualStrings("Hello, world!", msg.content);
    try std.testing.expect(msg.name == null);
}

test "ChatMessage - supports optional name" {
    const msg = ChatMessage{
        .role = "user",
        .content = "Hello",
        .name = "user_123",
    };
    try std.testing.expect(msg.name != null);
    try std.testing.expectEqualStrings("user_123", msg.name.?);
}

// ============================================================================
// ChatRequest Tests
// ============================================================================

test "ChatRequest.toJson - serializes basic request" {
    const allocator = std.testing.allocator;
    const messages = &[_]ChatMessage{
        .{ .role = "system", .content = "You are helpful" },
        .{ .role = "user", .content = "Hello" },
    };

    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = messages,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "You are helpful") != null);
}

test "ChatRequest.toJson - serializes with temperature" {
    const allocator = std.testing.allocator;
    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{.{ .role = "user", .content = "Hi" }},
        .temperature = 0.7,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"temperature\":0.7") != null);
}

test "ChatRequest.toJson - serializes with max_tokens" {
    const allocator = std.testing.allocator;
    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{.{ .role = "user", .content = "Hi" }},
        .max_tokens = 100,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"max_tokens\":100") != null);
}

test "ChatRequest.toJson - serializes with tools" {
    const allocator = std.testing.allocator;
    const tools = &[_]ToolDef{
        .{
            .function = .{
                .name = "get_weather",
                .description = "Get weather for a location",
                .parameters = "{\"type\":\"object\",\"properties\":{\"location\":{\"type\":\"string\"}}}",
            },
        },
    };

    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{.{ .role = "user", .content = "Weather?" }},
        .tools = tools,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"tools\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "get_weather") != null);
}

test "ChatRequest.toJson - escapes special characters" {
    const allocator = std.testing.allocator;
    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{
            .{ .role = "user", .content = "Say \"hello\"\nwith newline\nand tab\t" },
        },
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\\t") != null);
}

test "ChatRequest.toJson - serializes tool_choice" {
    const allocator = std.testing.allocator;
    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{.{ .role = "user", .content = "Use a tool" }},
        .tool_choice = "auto",
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_choice\":\"auto\"") != null);
}

test "ChatRequest.toJson - stream option" {
    const allocator = std.testing.allocator;
    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{.{ .role = "user", .content = "Stream" }},
        .stream = true,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"stream\":true") != null);
}

// ============================================================================
// ChatResponse Tests
// ============================================================================

test "ChatResponse.getContent - extracts from message" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .message = .{ .role = "assistant", .content = "Hello!" },
                .finish_reason = "stop",
            },
        },
    };

    const content = response.getContent();
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("Hello!", content.?);
}

test "ChatResponse.getContent - extracts from delta" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion.chunk",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .delta = .{ .content = "Streaming response..." },
            },
        },
    };

    const content = response.getContent();
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("Streaming response...", content.?);
}

test "ChatResponse.getContent - returns null on empty choices" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{},
    };

    const content = response.getContent();
    try std.testing.expect(content == null);
}

test "ChatResponse.getContent - returns null on empty content" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .message = .{ .role = "assistant", .content = "" },
                .finish_reason = "stop",
            },
        },
    };

    const content = response.getContent();
    try std.testing.expect(content == null);
}

test "ChatResponse.getToolCalls - extracts tool calls" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .tool_calls = &.{
                    .{
                        .id = "call_abc123",
                        .function = .{ .name = "get_weather", .arguments = "{\"location\":\"Tokyo\"}" },
                    },
                },
                .finish_reason = "tool_calls",
            },
        },
    };

    const tool_calls = response.getToolCalls();
    try std.testing.expect(tool_calls != null);
    try std.testing.expectEqual(@as(usize, 1), tool_calls.?.len);
    try std.testing.expectEqualStrings("call_abc123", tool_calls.?[0].id);
    try std.testing.expectEqualStrings("get_weather", tool_calls.?[0].function.name);
}

test "ChatResponse.getToolCalls - returns null when no tool calls" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .message = .{ .role = "assistant", .content = "Hello!" },
                .finish_reason = "stop",
            },
        },
    };

    const tool_calls = response.getToolCalls();
    try std.testing.expect(tool_calls == null);
}

test "ChatResponse.getFinishReason - returns reason" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .message = .{ .role = "assistant", .content = "Done" },
                .finish_reason = "stop",
            },
        },
    };

    const reason = response.getFinishReason();
    try std.testing.expect(reason != null);
    try std.testing.expectEqualStrings("stop", reason.?);
}

// ============================================================================
// ToolDef and FunctionDef Tests
// ============================================================================

test "FunctionDef - creates valid definition" {
    const fn_def = FunctionDef{
        .name = "test_function",
        .description = "A test function",
        .parameters = "{\"type\":\"object\"}",
    };

    try std.testing.expectEqualStrings("test_function", fn_def.name);
    try std.testing.expectEqualStrings("A test function", fn_def.description.?);
    try std.testing.expectEqualStrings("{\"type\":\"object\"}", fn_def.parameters.?);
}

test "FunctionDef - optional fields can be null" {
    const fn_def = FunctionDef{
        .name = "minimal_function",
    };

    try std.testing.expectEqualStrings("minimal_function", fn_def.name);
    try std.testing.expect(fn_def.description == null);
    try std.testing.expect(fn_def.parameters == null);
}

test "ToolDef - creates valid tool" {
    const tool = ToolDef{
        .type = "function",
        .function = .{
            .name = "my_tool",
            .description = "Does something",
            .parameters = "{}",
        },
    };

    try std.testing.expectEqualStrings("function", tool.type);
    try std.testing.expectEqualStrings("my_tool", tool.function.name);
}

test "ToolDef - default type is function" {
    const tool = ToolDef{
        .function = .{ .name = "test" },
    };

    try std.testing.expectEqualStrings("function", tool.type);
}

// ============================================================================
// LLMClient Initialization Tests
// ============================================================================

test "LLMClient.init - uses default model when empty" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "fake-key", .openai, "");

    try std.testing.expectEqualStrings("gpt-4o", client.model);
}

test "LLMClient.init - uses provided model" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "fake-key", .openai, "gpt-4-turbo");

    try std.testing.expectEqualStrings("gpt-4-turbo", client.model);
}

test "LLMClient.init - sets provider base URL" {
    const allocator = std.testing.allocator;

    const openai_client = LLMClient.init(allocator, "key", .openai, "gpt-4o");
    try std.testing.expectEqualStrings("https://api.openai.com/v1", openai_client.base_url);

    const anthropic_client = LLMClient.init(allocator, "key", .anthropic, "claude-3");
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1", anthropic_client.base_url);
}

test "LLMClient.init - stores API key" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "secret-api-key-123", .openai, "gpt-4o");

    try std.testing.expectEqualStrings("secret-api-key-123", client.api_key);
}

// ============================================================================
// Provider Routing Tests
// ============================================================================

test "Provider routing - Kimi routes to correct base URL" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "kimi-key", .kimi, "moonshot-v1-8k");

    try std.testing.expectEqualStrings("https://api.kimi.com/coding/v1", client.base_url);
    try std.testing.expectEqualStrings("moonshot-v1-8k", client.model);
}

test "Provider routing - Bailian (Alibaba) routes correctly" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "ali-key", .bailian, "qwen-plus");

    try std.testing.expectEqualStrings("https://dashscope.aliyuncs.com/compatible-mode/v1", client.base_url);
}

test "Provider routing - Volcano routes correctly" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "volc-key", .volcano, "doubao-pro-32k");

    try std.testing.expectEqualStrings("https://ark.cn-beijing.volces.com/api/v3", client.base_url);
}

// ============================================================================
// Error Response Parsing Tests
// ============================================================================

test "LLMClient.extractContent - handles error responses" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "key", .openai, "gpt-4o");

    const error_response = "{\"error\":{\"message\":\"Invalid API key\",\"type\":\"invalid_request_error\",\"code\":\"invalid_api_key\"}}";

    const result = client.extractContent(error_response);
    try std.testing.expect(result != null);
    try std.testing.expect(std.mem.indexOf(u8, result.?, "Invalid API key") != null);
    allocator.free(result.?);
}

test "LLMClient.extractContent - handles invalid JSON" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "key", .openai, "gpt-4o");

    const invalid_json = "This is not JSON at all!";
    const result = client.extractContent(invalid_json);

    try std.testing.expect(result != null);
    allocator.free(result.?);
}

// ============================================================================
// Response Structure Tests
// ============================================================================

test "ChatResponse.Usage - creates valid usage" {
    const usage = ChatResponse.Usage{
        .prompt_tokens = 100,
        .completion_tokens = 50,
        .total_tokens = 150,
    };

    try std.testing.expectEqual(@as(u32, 100), usage.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), usage.completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), usage.total_tokens);
}

test "ChatResponse.ToolCall.Function - creates valid function" {
    const func = ChatResponse.ToolCall.Function{
        .name = "test_func",
        .arguments = "{\"arg1\":\"value1\"}",
    };

    try std.testing.expectEqualStrings("test_func", func.name);
    try std.testing.expectEqualStrings("{\"arg1\":\"value1\"}", func.arguments);
}

test "ChatResponse.ToolCall - creates valid tool call" {
    const tool_call = ChatResponse.ToolCall{
        .id = "call_123",
        .type = "function",
        .function = .{ .name = "test", .arguments = "{}" },
    };

    try std.testing.expectEqualStrings("call_123", tool_call.id);
    try std.testing.expectEqualStrings("function", tool_call.type);
}

test "ChatResponse.Choice.Delta - defaults to null" {
    const delta = ChatResponse.Choice.Delta{};
    try std.testing.expect(delta.role == null);
    try std.testing.expect(delta.content == null);
    try std.testing.expect(delta.tool_calls == null);
}

// ============================================================================
// Multiple Choice Tests
// ============================================================================

test "ChatResponse - multiple choices handled" {
    const response = ChatResponse{
        .id = "chat-123",
        .object = "chat.completion",
        .created = 1234567890,
        .model = "gpt-4o",
        .choices = &.{
            .{
                .index = 0,
                .message = .{ .role = "assistant", .content = "First choice" },
                .finish_reason = "stop",
            },
            .{
                .index = 1,
                .message = .{ .role = "assistant", .content = "Second choice" },
                .finish_reason = "stop",
            },
        },
    };

    const content = response.getContent();
    try std.testing.expect(content != null);
    try std.testing.expectEqualStrings("First choice", content.?);
}

// ============================================================================
// Edge Cases
// ============================================================================

test "Edge case - empty model name" {
    const allocator = std.testing.allocator;
    const client = LLMClient.init(allocator, "key", .openai, "");

    try std.testing.expect(client.model.len > 0);
}

test "Edge case - very long content in message" {
    const allocator = std.testing.allocator;
    const long_content = "A".** 10000;
    const messages = &[_]ChatMessage{.{ .role = "user", .content = long_content }};

    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = messages,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(json.len > 10000);
}

test "Edge case - unicode in messages" {
    const allocator = std.testing.allocator;
    const messages = &[_]ChatMessage{
        .{ .role = "user", .content = "你好世界 🌍 مرحبا" },
    };

    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = messages,
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "你好世界") != null);
}

test "Edge case - empty messages array" {
    const allocator = std.testing.allocator;
    const request = ChatRequest{
        .model = "gpt-4o",
        .messages = &.{},
    };

    const json = try request.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"messages\":[]") != null);
}
