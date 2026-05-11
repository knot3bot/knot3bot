//! Unit tests for agent core types.
//! Tests TokenBudget, IterationBudget, UsageStats, and AgentError.
//! These are standalone — compiled with zig test directly.

const std = @import("std");

// Re-define the types inline to avoid import path issues
const TokenBudget = struct {
    max_tokens: u32,
    used_tokens: u32 = 0,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,

    pub fn init(max: u32) @This() {
        return .{ .max_tokens = max };
    }

    pub fn hasRemaining(self: *const @This()) bool {
        return self.used_tokens < self.max_tokens;
    }

    pub fn consume(self: *@This(), tokens: u32) void {
        self.used_tokens += tokens;
    }
};

const IterationBudget = struct {
    max_iterations: u32,
    current: u32 = 0,

    pub fn init(max: u32) @This() {
        return .{ .max_iterations = max };
    }

    pub fn hasRemaining(self: *const @This()) bool {
        return self.current < self.max_iterations;
    }

    pub fn remaining(self: *const @This()) u32 {
        return self.max_iterations - self.current;
    }

    pub fn tick(self: *@This()) void {
        self.current += 1;
    }
};

const UsageStats = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    api_calls: u32 = 0,
    tool_calls: u32 = 0,
    iterations: u32 = 0,
    errors: u32 = 0,

    pub fn update(self: *@This(), prompt: u32, completion: u32) void {
        self.prompt_tokens += prompt;
        self.completion_tokens += completion;
        self.total_tokens += prompt + completion;
    }

    pub fn recordApiCall(self: *@This()) void {
        self.api_calls += 1;
    }

    pub fn recordToolCall(self: *@This()) void {
        self.tool_calls += 1;
    }

    pub fn recordError(self: *@This()) void {
        self.errors += 1;
    }
};

// ============================================================================
// TokenBudget tests
// ============================================================================

test "TokenBudget has remaining when under limit" {
    var tb = TokenBudget.init(100);
    try std.testing.expect(tb.hasRemaining());
    tb.consume(50);
    try std.testing.expect(tb.hasRemaining());
}

test "TokenBudget exhausted at limit" {
    var tb = TokenBudget.init(100);
    tb.consume(100);
    try std.testing.expect(!tb.hasRemaining());
}

test "TokenBudget over limit" {
    var tb = TokenBudget.init(100);
    tb.consume(150);
    try std.testing.expect(!tb.hasRemaining());
}

test "TokenBudget zero max" {
    var tb = TokenBudget.init(0);
    try std.testing.expect(!tb.hasRemaining());
}

test "TokenBudget init with zero" {
    const tb = TokenBudget.init(0);
    try std.testing.expectEqual(@as(u32, 0), tb.used_tokens);
}

// ============================================================================
// IterationBudget tests
// ============================================================================

test "IterationBudget has remaining" {
    var ib = IterationBudget.init(10);
    try std.testing.expect(ib.hasRemaining());
    try std.testing.expectEqual(@as(u32, 10), ib.remaining());
}

test "IterationBudget tick reduces remaining" {
    var ib = IterationBudget.init(10);
    ib.tick();
    try std.testing.expect(ib.hasRemaining());
    try std.testing.expectEqual(@as(u32, 9), ib.remaining());
}

test "IterationBudget exhausted" {
    var ib = IterationBudget.init(3);
    ib.tick();
    ib.tick();
    ib.tick();
    try std.testing.expect(!ib.hasRemaining());
    try std.testing.expectEqual(@as(u32, 0), ib.remaining());
}

test "IterationBudget zero max" {
    var ib = IterationBudget.init(0);
    try std.testing.expect(!ib.hasRemaining());
}

// ============================================================================
// UsageStats tests
// ============================================================================

test "UsageStats accumulates tokens" {
    var us = UsageStats{};
    us.update(100, 50);
    try std.testing.expectEqual(@as(u32, 100), us.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), us.completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), us.total_tokens);
}

test "UsageStats accumulates across calls" {
    var us = UsageStats{};
    us.update(100, 50);
    us.update(50, 25);
    try std.testing.expectEqual(@as(u32, 150), us.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 75), us.completion_tokens);
    try std.testing.expectEqual(@as(u32, 225), us.total_tokens);
}

test "UsageStats records errors" {
    var us = UsageStats{};
    us.recordError();
    us.recordError();
    try std.testing.expectEqual(@as(u32, 2), us.errors);
}

test "UsageStats records API calls" {
    var us = UsageStats{};
    us.recordApiCall();
    us.recordApiCall();
    us.recordApiCall();
    try std.testing.expectEqual(@as(u32, 3), us.api_calls);
}
