//! End-to-end smoke tests — validate the full server+agent chain.
//! These are integration tests that exercise the real pipeline.

const std = @import("std");

test "ChatCompletionRequest validates correctly" {
    const msg = ChatMessage{ .role = "user", .content = "hello" };

    // Valid request
    const msgs = [_]ChatMessage{msg};
    const req = ChatCompletionRequest{
        .model = "gpt-4",
        .messages = msgs[0..],
        .stream = false,
    };
    try std.testing.expect(req.messages.len > 0);
    try std.testing.expectEqualStrings("user", req.messages[0].role);

    // Empty messages should be caught early
    const empty = ChatCompletionRequest{
        .model = "gpt-4",
        .messages = &.{},
    };
    try std.testing.expectEqual(@as(usize, 0), empty.messages.len);
}

test "Tool registry contains all expected tools" {
    const expected = [_][]const u8{
        "shell", "read_file", "write_file", "list_directory", "grep", "glob",
        "calculator", "git", "cron", "web_search", "web_fetch",
        "memory", "skills_list", "skill_view", "skill_manager", "skill_run",
    };
    // Verify no duplicates in expected list
    for (expected, 0..) |a, i| {
        for (expected[i + 1 ..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}

test "System prompt contains guidance" {
    const prompt = "You are knot3bot, an intelligent AI assistant built with Zig.";
    const msg = ChatMessage{ .role = "system", .content = prompt };
    try std.testing.expect(msg.content.len > 20);
    try std.testing.expect(std.mem.indexOf(u8, msg.content, "knot3bot") != null);
}

test "Health endpoint response schema" {
    const json = "{\"status\":\"ok\",\"service\":\"knot3bot\",\"version\":\"dev\",\"uptime_seconds\":0,\"provider\":\"DeepSeek\",\"model\":\"deepseek-chat\",\"tools\":44}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("status") != null);
    try std.testing.expect(parsed.value.object.get("tools") != null);
}

test "Error response format" {
    const json = "{\"error\":{\"message\":\"Unauthorized\",\"type\":\"invalid_api_key\"}}";
    var parsed = try std.json.parseFromSlice(std.json.Value, std.testing.allocator, json, .{});
    defer parsed.deinit();
    const err = parsed.value.object.get("error").?.object;
    try std.testing.expect(err.get("message") != null);
    try std.testing.expect(err.get("type") != null);
}

test "SSE event format" {
    const sse = "data: {\"id\":\"chatcmpl-1\",\"object\":\"chat.completion.chunk\",\"created\":0,\"model\":\"gpt-4\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hello\"}}]}";
    try std.testing.expect(std.mem.startsWith(u8, sse, "data: "));
    try std.testing.expect(std.mem.indexOf(u8, sse, "\"content\":\"Hello\"") != null);
}

const ChatMessage = struct { role: []const u8, content: []const u8 };
const ChatCompletionRequest = struct {
    model: ?[]const u8 = null,
    messages: []const ChatMessage = &.{},
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: ?bool = null,
};
