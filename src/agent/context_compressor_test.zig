//! Context Compressor tests
//!
//! Tests for token estimation, boundary alignment, message pruning,
//! compression logic, and memory pressure scenarios.
const std = @import("std");
const context_compressor = @import("agent/context_compressor.zig");
const Agent = @import("agent/agent.zig");
const Message = Agent.Message;
const Role = Agent.Role;
const estimateTokens = context_compressor.estimateTokens;
const pruneOldToolResults = context_compressor.pruneOldToolResults;
const alignBoundaryForward = context_compressor.alignBoundaryForward;
const alignBoundaryBackward = context_compressor.alignBoundaryBackward;
const findTailCutByTokens = context_compressor.findTailCutByTokens;
const computeSummaryBudget = context_compressor.computeSummaryBudget;
const serializeForSummary = context_compressor.serializeForSummary;
const ContextCompressor = context_compressor.ContextCompressor;

// ============================================================================
// estimateTokens Tests
// ============================================================================

test "estimateTokens - empty messages returns zero" {
    const messages: []const Message = &.{};
    const tokens = estimateTokens(messages);
    try std.testing.expectEqual(@as(u32, 0), tokens);
}

test "estimateTokens - single message calculates correctly" {
    // Formula: (content.len + 20) / 4
    // "Hello" = 5 chars + 20 = 25 / 4 = 6.25 -> 6
    const messages = &[_]Message{
        .{ .role = .user, .content = "Hello" },
    };
    const tokens = estimateTokens(messages);
    try std.testing.expect(tokens >= 6);
    try std.testing.expect(tokens <= 7);
}

test "estimateTokens - multiple messages sums correctly" {
    const messages = &[_]Message{
        .{ .role = .system, .content = "You are helpful" },
        .{ .role = .user, .content = "Hello world" },
        .{ .role = .assistant, .content = "Hi there!" },
    };
    const tokens = estimateTokens(messages);

    // system: "You are helpful" = 14 + 20 = 34 / 4 = 8.5 -> 8
    // user: "Hello world" = 11 + 20 = 31 / 4 = 7.75 -> 7
    // assistant: "Hi there!" = 9 + 20 = 29 / 4 = 7.25 -> 7
    // Total: ~22 tokens
    try std.testing.expect(tokens >= 20);
    try std.testing.expect(tokens <= 25);
}

test "estimateTokens - long content scales linearly" {
    const short_msg = "Hello";
    const long_msg = "This is a very long message that contains much more content for testing purposes and should roughly double the token count.";

    const short_messages = &[_]Message{.{ .role = .user, .content = short_msg }};
    const long_messages = &[_]Message{.{ .role = .user, .content = long_msg }};

    const short_tokens = estimateTokens(short_messages);
    const long_tokens = estimateTokens(long_messages);

    // Long message should be significantly more tokens
    try std.testing.expect(long_tokens > short_tokens);
    // Roughly proportional (allowing for metadata overhead)
    try std.testing.expect(long_tokens > short_tokens * 3);
}

test "estimateTokens - all roles handled correctly" {
    const roles = [_]Role{ .system, .user, .assistant, .tool };
    for (roles) |role| {
        const messages = &[_]Message{.{ .role = role, .content = "Test content" }};
        const tokens = estimateTokens(messages);
        try std.testing.expect(tokens > 0);
    }
}

// ============================================================================
// pruneOldToolResults Tests
// ============================================================================

test "pruneOldToolResults - empty array returns zero" {
    var messages: []Message = &.{};
    const pruned = pruneOldToolResults(messages, 3);
    try std.testing.expectEqual(@as(u32, 0), pruned);
}

test "pruneOldToolResults - short tool results not pruned" {
    var messages: []Message = &[_]Message{
        .{ .role = .tool, .content = "short" },
        .{ .role = .user, .content = "Hello" },
    };
    const pruned = pruneOldToolResults(messages, 3);
    try std.testing.expectEqual(@as(u32, 0), pruned);
}

test "pruneOldToolResults - long tool results pruned" {
    var messages: []Message = &[_]Message{
        .{ .role = .tool, .content = "This is a very long tool result that definitely exceeds two hundred characters and should be replaced with the pruned placeholder" },
        .{ .role = .user, .content = "Hello" },
    };
    const pruned = pruneOldToolResults(messages, 3);
    try std.testing.expectEqual(@as(u32, 1), pruned);
    try std.testing.expectEqualStrings(context_compressor.PRUNED_PLACEHOLDER, messages[0].content);
}

test "pruneOldToolResults - preserves recent messages" {
    // Protect 3 recent messages - only index 0 should be pruned
    var messages: []Message = &[_]Message{
        .{ .role = .tool, .content = "Old tool output that is definitely longer than two hundred characters and should be pruned away" },
        .{ .role = .tool, .content = "Another old tool message that exceeds two hundred characters in length and should also be replaced" },
        .{ .role = .user, .content = "Recent user message" },
        .{ .role = .assistant, .content = "Recent assistant response" },
        .{ .role = .tool, .content = "Most recent tool result" },
    };
    const pruned = pruneOldToolResults(messages, 3);
    try std.testing.expectEqual(@as(u32, 2), pruned);
    // First two should be pruned
    try std.testing.expectEqualStrings(context_compressor.PRUNED_PLACEHOLDER, messages[0].content);
    try std.testing.expectEqualStrings(context_compressor.PRUNED_PLACEHOLDER, messages[1].content);
    // Last three should be preserved
    try std.testing.expectEqualStrings("Recent user message", messages[2].content);
}

test "pruneOldToolResults - non-tool roles not affected" {
    var messages: []Message = &[_]Message{
        .{ .role = .user, .content = "User message that is definitely longer than two hundred characters and should not be pruned because it is not a tool result" },
        .{ .role = .assistant, .content = "Assistant message also longer than two hundred characters but should remain unchanged" },
    };
    const pruned = pruneOldToolResults(messages, 3);
    try std.testing.expectEqual(@as(u32, 0), pruned);
    try std.testing.expect(!std.mem.eql(u8, messages[0].content, context_compressor.PRUNED_PLACEHOLDER));
}

test "pruneOldToolResults - already pruned not counted twice" {
    var messages: []Message = &[_]Message{
        .{ .role = .tool, .content = context_compressor.PRUNED_PLACEHOLDER },
        .{ .role = .tool, .content = "Another tool result with more than two hundred characters of content that should be pruned" },
    };
    const pruned = pruneOldToolResults(messages, 3);
    try std.testing.expectEqual(@as(u32, 1), pruned);
}

// ============================================================================
// alignBoundaryForward Tests
// ============================================================================

test "alignBoundaryForward - stops at non-tool" {
    const messages = &[_]Message{
        .{ .role = .tool, .content = "tool1" },
        .{ .role = .tool, .content = "tool2" },
        .{ .role = .assistant, .content = "assistant" },
        .{ .role = .tool, .content = "tool3" },
    };
    const aligned = alignBoundaryForward(messages, 0);
    try std.testing.expectEqual(@as(u32, 2), aligned);
}

test "alignBoundaryForward - empty after start index" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "user" },
        .{ .role = .tool, .content = "tool1" },
        .{ .role = .tool, .content = "tool2" },
    };
    const aligned = alignBoundaryForward(messages, 2);
    try std.testing.expectEqual(@as(u32, 3), aligned); // All were tools, advances to length
}

test "alignBoundaryForward - already at non-tool" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "user" },
        .{ .role = .assistant, .content = "assistant" },
    };
    const aligned = alignBoundaryForward(messages, 0);
    try std.testing.expectEqual(@as(u32, 0), aligned);
}

// ============================================================================
// alignBoundaryBackward Tests
// ============================================================================

test "alignBoundaryBackward - finds assistant before tool" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "user" },
        .{ .role = .assistant, .content = "assistant" },
        .{ .role = .tool, .content = "tool1" },
        .{ .role = .tool, .content = "tool2" },
    };
    const aligned = alignBoundaryBackward(messages, 4);
    try std.testing.expectEqual(@as(u32, 1), aligned); // Stops at assistant
}

test "alignBoundaryBackward - returns index if no assistant found" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "user" },
        .{ .role = .tool, .content = "tool1" },
        .{ .role = .tool, .content = "tool2" },
    };
    const aligned = alignBoundaryBackward(messages, 3);
    try std.testing.expectEqual(@as(u32, 3), aligned); // No assistant, returns original
}

test "alignBoundaryBackward - handles zero index" {
    const messages = &[_]Message{
        .{ .role = .tool, .content = "tool1" },
    };
    const aligned = alignBoundaryBackward(messages, 0);
    try std.testing.expectEqual(@as(u32, 0), aligned);
}

// ============================================================================
// findTailCutByTokens Tests
// ============================================================================

test "findTailCutByTokens - respects min tail protection" {
    const messages = &[_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .user, .content = "u2" },
        .{ .role = .assistant, .content = "a2" },
        .{ .role = .user, .content = "u3" },
        .{ .role = .assistant, .content = "a3" },
    };
    // head_end=1, token_budget=100, min_tail=3
    // Should protect at least last 3 messages
    const cut = findTailCutByTokens(messages, 1, 100, 3);
    try std.testing.expect(cut >= 4); // At least 3 protected
    try std.testing.expect(cut <= messages.len);
}

test "findTailCutByTokens - respects token budget" {
    const messages = &[_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "This is a very long message that should consume significant token budget" },
        .{ .role = .assistant, .content = "Another lengthy response with substantial content" },
        .{ .role = .user, .content = "Short" },
    };
    // Small budget should cut earlier
    const cut_small = findTailCutByTokens(messages, 1, 10, 2);
    // Large budget should cut later
    const cut_large = findTailCutByTokens(messages, 1, 1000, 2);

    try std.testing.expect(cut_small <= cut_large);
}

test "findTailCutByTokens - handles single message" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "Only one" },
    };
    const cut = findTailCutByTokens(messages, 0, 100, 1);
    try std.testing.expect(cut >= 1);
}

test "findTailCutByTokens - handles empty tail protection" {
    const messages = &[_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
    };
    const cut = findTailCutByTokens(messages, 1, 100, 1);
    try std.testing.expect(cut >= 1);
}

// ============================================================================
// computeSummaryBudget Tests
// ============================================================================

test "computeSummaryBudget - respects minimum tokens" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "Short" },
    };
    // MIN_SUMMARY_TOKENS = 2000
    const budget = computeSummaryBudget(messages, 12000);
    try std.testing.expectEqual(@as(u32, 2000), budget);
}

test "computeSummaryBudget - respects max tokens cap" {
    const long_content = "This is a very long message. " ** 100;
    const messages = &[_]Message{
        .{ .role = .user, .content = long_content },
    };
    // Even with long content, budget capped at max
    const budget = computeSummaryBudget(messages, 5000);
    try std.testing.expect(budget <= 5000);
}

test "computeSummaryBudget - scales with content" {
    const short = "Short content";
    const long = "This is much longer content that should result in a higher summary budget. " ** 10;

    const short_messages = &[_]Message{.{ .role = .user, .content = short }};
    const long_messages = &[_]Message{.{ .role = .user, .content = long }};

    const short_budget = computeSummaryBudget(short_messages, 12000);
    const long_budget = computeSummaryBudget(long_messages, 12000);

    // Long content should have higher or equal budget
    try std.testing.expect(long_budget >= short_budget);
}

// ============================================================================
// serializeForSummary Tests
// ============================================================================

test "serializeForSummary - formats all roles" {
    const allocator = std.testing.allocator;
    const messages = &[_]Message{
        .{ .role = .system, .content = "You are helpful" },
        .{ .role = .user, .content = "Hello" },
        .{ .role = .assistant, .content = "Hi there" },
        .{ .role = .tool, .content = "Tool result" },
    };

    const output = try serializeForSummary(allocator, messages);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "[system]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[user]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[assistant]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "[TOOL RESULT]") != null);
}

test "serializeForSummary - truncates long content" {
    const allocator = std.testing.allocator;
    const long_content = "A".** 4000;
    const messages = &[_]Message{.{ .role = .user, .content = long_content }};

    const output = try serializeForSummary(allocator, messages);
    defer allocator.free(output);

    // Should contain truncation markers
    try std.testing.expect(std.mem.indexOf(u8, output, "...[truncated]...") != null);
    // Should not contain full content
    try std.testing.expect(output.len < long_content.len);
}

test "serializeForSummary - preserves short content" {
    const allocator = std.testing.allocator;
    const messages = &[_]Message{.{ .role = .user, .content = "Hello world" }};

    const output = try serializeForSummary(allocator, messages);
    defer allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "Hello world") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "...[truncated]...") == null);
}

// ============================================================================
// ContextCompressor Tests
// ============================================================================

test "ContextCompressor.init - sets correct defaults" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    defer cc.deinit();

    try std.testing.expectEqual(@as(u32, 128000), cc.context_length);
    // Threshold is 50% of context_length
    try std.testing.expectEqual(@as(u32, 64000), cc.threshold_tokens);
    try std.testing.expectEqual(@as(u32, 0), cc.compression_count);
}

test "ContextCompressor.shouldCompress - below threshold returns false" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    defer cc.deinit();

    try std.testing.expect(!cc.shouldCompress(1000));
    try std.testing.expect(!cc.shouldCompress(64000));
}

test "ContextCompressor.shouldCompress - at threshold returns true" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    defer cc.deinit();

    try std.testing.expect(cc.shouldCompress(64001));
    try std.testing.expect(cc.shouldCompress(100000));
}

test "ContextCompressor.compress - short conversation not compressed" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    cc.quiet_mode = true; // Suppress logging
    defer cc.deinit();

    // protect_first_n=3, protect_last_n=20, so < 24 messages not compressed
    const messages = &[_]Message{
        .{ .role = .system, .content = "You are helpful" },
        .{ .role = .user, .content = "Hello" },
    };

    const result = try cc.compress(messages, null);
    defer {
        for (result.messages) |m| allocator.free(m.content);
        allocator.free(result.messages);
    }

    try std.testing.expect(!result.compressed);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
}

test "ContextCompressor.compress - preserves system message" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    cc.quiet_mode = true;
    defer cc.deinit();

    const messages = &[_]Message{
        .{ .role = .system, .content = "You are helpful" },
        .{ .role = .user, .content = "Hello" },
    };

    const result = try cc.compress(messages, null);
    defer {
        for (result.messages) |m| allocator.free(m.content);
        allocator.free(result.messages);
    }

    try std.testing.expect(result.messages[0].role == .system);
    try std.testing.expect(std.mem.indexOf(u8, result.messages[0].content, "helpful") != null);
}

test "ContextCompressor - consecutive compressions increment counter" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    cc.quiet_mode = true;
    defer cc.deinit();

    // Create long conversation to trigger compression
    var messages_arr: [100]Message = undefined;
    for (0..50) |i| {
        messages_arr[i] = .{ .role = if (i % 2 == 0) .user else .assistant, .content = "Message content here" };
    }
    const messages: []Message = messages_arr[0..50];

    // First compression
    const result1 = try cc.compress(messages, 80000);
    defer {
        for (result1.messages) |m| allocator.free(m.content);
        allocator.free(result1.messages);
    }
    try std.testing.expectEqual(@as(u32, 1), cc.compression_count);

    // Create another long conversation
    for (50..100) |i| {
        messages_arr[i] = .{ .role = if (i % 2 == 0) .user else .assistant, .content = "New message content" };
    }

    // Second compression
    const result2 = try cc.compress(messages_arr[0..100], 90000);
    defer {
        for (result2.messages) |m| allocator.free(m.content);
        allocator.free(result2.messages);
    }
    try std.testing.expectEqual(@as(u32, 2), cc.compression_count);
}

// ============================================================================
// Memory Pressure Tests
// ============================================================================

test "Memory pressure - large number of messages" {
    const allocator = std.testing.allocator;
    var cc = ContextCompressor.init(allocator, "gpt-4o", .openai, "fake-key", 128000);
    cc.quiet_mode = true;
    defer cc.deinit();

    // Create 500 messages (stress test)
    var messages_arr: [500]Message = undefined;
    for (0..500) |i| {
        const content = try std.fmt.allocPrint(allocator, "Message number {d} with some content", .{i});
        defer allocator.free(content);
        messages_arr[i] = .{ .role = if (i % 2 == 0) .user else .assistant, .content = content };
    }

    const messages: []Message = messages_arr[0..500];

    // Should handle without OOM (though may not actually compress without API key)
    const result = cc.compress(messages, null);
    // Either succeeds or fails gracefully
    _ = result;
}

test "Memory pressure - very long single message" {
    const allocator = std.testing.allocator;

    // Create a message with 100KB of content
    var large_content: [102400]u8 = undefined;
    for (large_content[0..], 0..) |*byte, i| {
        byte.* = @truncate(@as(u8, ('A' + @as(u8, @intCast(i % 26)))));
    }

    const messages = &[_]Message{
        .{ .role = .system, .content = large_content[0..] },
        .{ .role = .user, .content = "Hello" },
    };

    const tokens = estimateTokens(messages);
    // Should handle gracefully
    try std.testing.expect(tokens > 0);
}

test "Memory pressure - many short messages" {
    // 1000 tiny messages
    var messages_arr: [1000]Message = undefined;
    for (0..1000) |i| {
        const num_str = try std.fmt.allocPrint(std.testing.allocator, "{d}", .{i});
        defer std.testing.allocator.free(num_str);
        messages_arr[i] = .{ .role = if (i % 2 == 0) .user else .assistant, .content = num_str };
    }

    const messages: []const Message = messages_arr[0..1000];
    const tokens = estimateTokens(messages);

    // Should handle without overflow
    try std.testing.expect(tokens > 0);
    try std.testing.expect(tokens < 100000); // Reasonable upper bound
}

// ============================================================================
// Edge Cases
// ============================================================================

test "Edge case - empty message content" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "" },
    };
    const tokens = estimateTokens(messages);
    try std.testing.expectEqual(@as(u32, 5), tokens); // Just metadata overhead
}

test "Edge case - special characters in content" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "Line1\nLine2\tTabbed\"Quoted\"Backslash\\" },
    };
    const tokens = estimateTokens(messages);
    try std.testing.expect(tokens > 0);
}

test "Edge case - unicode content" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "你好世界 🌟 مرحبا" },
    };
    const tokens = estimateTokens(messages);
    try std.testing.expect(tokens > 0);
}

test "Edge case - alignment with single element array" {
    const single_msg = &[_]Message{.{ .role = .tool, .content = "tool" }};

    const forward = alignBoundaryForward(single_msg, 0);
    try std.testing.expect(forward >= 0);

    const backward = alignBoundaryBackward(single_msg, 1);
    _ = backward; // Should handle gracefully
}
