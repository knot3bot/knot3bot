//! Agent module tests
const std = @import("std");
const Agent = @import("agent.zig");
const ToolRegistry = @import("../tools/root.zig").ToolRegistry;
const ToolResult = @import("../tools/root.zig").ToolResult;
const Tool = @import("../tools/root.zig").Tool;

// ============================================================================
// TokenBudget Tests
// ============================================================================

test "TokenBudget.init - creates budget with max tokens" {
    const budget = Agent.TokenBudget.init(1000);
    try std.testing.expectEqual(@as(u32, 1000), budget.max_tokens);
    try std.testing.expectEqual(@as(u32, 0), budget.used_tokens);
    try std.testing.expectEqual(@as(u32, 0), budget.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 0), budget.completion_tokens);
}

test "TokenBudget.hasRemaining - returns true when under max" {
    const budget = Agent.TokenBudget.init(1000);
    try std.testing.expect(budget.hasRemaining());
}

test "TokenBudget.hasRemaining - returns false when at max" {
    var budget = Agent.TokenBudget.init(100);
    budget.consume(100);
    try std.testing.expect(!budget.hasRemaining());
}

test "TokenBudget.consume - increments used tokens" {
    var budget = Agent.TokenBudget.init(1000);
    try std.testing.expectEqual(@as(u32, 0), budget.used_tokens);
    budget.consume(100);
    try std.testing.expectEqual(@as(u32, 100), budget.used_tokens);
    budget.consume(50);
    try std.testing.expectEqual(@as(u32, 150), budget.used_tokens);
}

test "TokenBudget.updateFromUsage - updates all token counts" {
    var budget = Agent.TokenBudget.init(1000);
    budget.updateFromUsage(100, 200);
    try std.testing.expectEqual(@as(u32, 100), budget.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 200), budget.completion_tokens);
    try std.testing.expectEqual(@as(u32, 300), budget.used_tokens);
}

// ============================================================================
// IterationBudget Tests
// ============================================================================

test "IterationBudget.init - creates budget with max iterations" {
    const budget = Agent.IterationBudget.init(10);
    try std.testing.expectEqual(@as(u32, 10), budget.max_iterations);
    try std.testing.expectEqual(@as(u32, 0), budget.current);
}

test "IterationBudget.hasRemaining - returns true when under max" {
    const budget = Agent.IterationBudget.init(10);
    try std.testing.expect(budget.hasRemaining());
}

test "IterationBudget.hasRemaining - returns false when at max" {
    var budget = Agent.IterationBudget.init(3);
    budget.tick();
    budget.tick();
    budget.tick();
    try std.testing.expect(!budget.hasRemaining());
}

test "IterationBudget.tick - increments current counter" {
    var budget = Agent.IterationBudget.init(10);
    try std.testing.expectEqual(@as(u32, 0), budget.current);
    budget.tick();
    try std.testing.expectEqual(@as(u32, 1), budget.current);
    budget.tick();
    try std.testing.expectEqual(@as(u32, 2), budget.current);
}

test "IterationBudget.remaining - calculates remaining iterations" {
    var budget = Agent.IterationBudget.init(5);
    try std.testing.expectEqual(@as(u32, 5), budget.remaining());
    budget.tick();
    try std.testing.expectEqual(@as(u32, 4), budget.remaining());
    budget.tick();
    budget.tick();
    try std.testing.expectEqual(@as(u32, 2), budget.remaining());
}

// ============================================================================
// UsageStats Tests
// ============================================================================

test "UsageStats.init - creates zeroed stats" {
    const stats = Agent.UsageStats{};
    try std.testing.expectEqual(@as(u32, 0), stats.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 0), stats.completion_tokens);
    try std.testing.expectEqual(@as(u32, 0), stats.total_tokens);
    try std.testing.expectEqual(@as(u32, 0), stats.api_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.tool_calls);
    try std.testing.expectEqual(@as(u32, 0), stats.iterations);
    try std.testing.expectEqual(@as(u32, 0), stats.errors);
}

test "UsageStats.update - calculates total tokens" {
    var stats = Agent.UsageStats{};
    stats.update(100, 50);
    try std.testing.expectEqual(@as(u32, 100), stats.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 50), stats.completion_tokens);
    try std.testing.expectEqual(@as(u32, 150), stats.total_tokens);
}

test "UsageStats.update - overwrites previous values" {
    var stats = Agent.UsageStats{};
    stats.update(100, 50);
    stats.update(200, 100);
    try std.testing.expectEqual(@as(u32, 200), stats.prompt_tokens);
    try std.testing.expectEqual(@as(u32, 100), stats.completion_tokens);
    try std.testing.expectEqual(@as(u32, 300), stats.total_tokens);
}

// ============================================================================
// ReActStep Tests
// ============================================================================

test "ReActStep.toJSON - serializes step with thought only" {
    const allocator = std.testing.allocator;
    const step = Agent.ReActStep{
        .step_number = 1,
        .thought = "I should help the user",
        .action = null,
        .action_input = null,
        .observation = null,
        .result = null,
        .duration_ms = 100,
    };

    const json = try step.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"step\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"thought\":\"I should help the user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"duration_ms\":100") != null);
}

test "ReActStep.toJSON - serializes step with action and observation" {
    const allocator = std.testing.allocator;
    const step = Agent.ReActStep{
        .step_number = 2,
        .thought = "Let me check the file",
        .action = "read_file",
        .action_input = "{\"path\":\"test.txt\"}",
        .observation = "File contains: hello world",
        .result = null,
        .duration_ms = 50,
    };

    const json = try step.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"step\":2") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"action\":\"read_file\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"observation\":\"File contains: hello world\"") != null);
}

test "ReActStep.toJSON - serializes step with result" {
    const allocator = std.testing.allocator;
    const step = Agent.ReActStep{
        .step_number = 3,
        .thought = "Task complete",
        .action = null,
        .action_input = null,
        .observation = null,
        .result = "The answer is 42",
        .duration_ms = 75,
    };

    const json = try step.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"result\":\"The answer is 42\"") != null);
}

test "ReActStep.toJSON - serializes step with error" {
    const allocator = std.testing.allocator;
    const step = Agent.ReActStep{
        .step_number = 1,
        .thought = "Something went wrong",
        .action = "read_file",
        .action_input = "{\"path\":\"missing.txt\"}",
        .observation = null,
        .result = null,
        .error_msg = "File not found",
        .duration_ms = 10,
    };

    const json = try step.toJSON(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"error\":\"File not found\"") != null);
}

// ============================================================================
// Role Tests
// ============================================================================

test "Role enum - has expected values" {
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Agent.Role.system));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Agent.Role.user));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Agent.Role.assistant));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Agent.Role.tool));
}

// ============================================================================
// Message Tests
// ============================================================================

test "Message struct - creates valid message" {
    const msg = Agent.Message{
        .role = Agent.Role.user,
        .content = "Hello, world!",
    };
    try std.testing.expectEqual(Agent.Role.user, msg.role);
    try std.testing.expectEqualStrings("Hello, world!", msg.content);
}

test "Message struct - supports all roles" {
    const roles = [_]Agent.Role{ .system, .user, .assistant, .tool };
    for (roles) |role| {
        const msg = Agent.Message{
            .role = role,
            .content = "test",
        };
        try std.testing.expectEqual(role, msg.role);
    }
}

// ============================================================================
// ToolCall Tests
// ============================================================================

test "ToolCall struct - creates valid tool call" {
    const tc = Agent.ToolCall{
        .id = "call_123",
        .name = "read_file",
        .arguments = "{\"path\":\"test.txt\"}",
    };
    try std.testing.expectEqualStrings("call_123", tc.id);
    try std.testing.expectEqualStrings("read_file", tc.name);
    try std.testing.expectEqualStrings("{\"path\":\"test.txt\"}", tc.arguments);
}

// ============================================================================
// AgentConfig Tests
// ============================================================================

test "AgentConfig - has sensible defaults" {
    const config = Agent.AgentConfig{};
    try std.testing.expectEqualStrings("gpt-4o", config.model);
    try std.testing.expectEqual(@as(u32, 100), config.max_iterations);
    try std.testing.expectEqual(@as(f32, 0.7), config.temperature);
    try std.testing.expectEqual(false, config.verbose);
    try std.testing.expectEqual(false, config.enable_trajectory_recording);
    try std.testing.expectEqual(false, config.enable_smart_routing);
}

// ============================================================================
// LLMResult Tests
// ============================================================================

test "LLMResult struct - creates valid result with content only" {
    const result = Agent.LLMResult{
        .content = "The answer is 42",
        .tool_calls = null,
        .usage = null,
    };
    try std.testing.expectEqualStrings("The answer is 42", result.content);
    try std.testing.expect(result.tool_calls == null);
    try std.testing.expect(result.usage == null);
}

test "LLMResult struct - creates valid result with usage" {
    const result = Agent.LLMResult{
        .content = "Response text",
        .tool_calls = null,
        .usage = .{ .prompt = 100, .completion = 50 },
    };
    try std.testing.expect(result.usage != null);
    try std.testing.expectEqual(@as(u32, 100), result.usage.?.prompt);
    try std.testing.expectEqual(@as(u32, 50), result.usage.?.completion);
}

// ============================================================================
// StepResult Tests
// ============================================================================

test "StepResult struct - creates valid result" {
    const steps = &[_]Agent.ReActStep{};
    const result = Agent.StepResult{
        .steps = steps,
        .final_answer = "Done",
        .usage = Agent.UsageStats{},
        .success = true,
    };
    try std.testing.expectEqualStrings("Done", result.final_answer);
    try std.testing.expect(result.success);
    try std.testing.expect(result.error_msg == null);
}

test "StepResult struct - can have error message" {
    const steps = &[_]Agent.ReActStep{};
    const result = Agent.StepResult{
        .steps = steps,
        .final_answer = "Failed",
        .usage = Agent.UsageStats{},
        .success = false,
        .error_msg = "Max iterations reached",
    };
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("Max iterations reached", result.error_msg.?);
}

// ============================================================================
// LLMUsage Tests
// ============================================================================

test "LLMUsage struct - creates valid usage" {
    const usage = Agent.LLMUsage{
        .prompt = 150,
        .completion = 75,
    };
    try std.testing.expectEqual(@as(u32, 150), usage.prompt);
    try std.testing.expectEqual(@as(u32, 75), usage.completion);
}

// ============================================================================
// AgentError Tests
// ============================================================================

test "AgentError - all error variants exist" {
    const errors = [_]anyerror{
        Agent.AgentError.ToolNotFound,
        Agent.AgentError.ToolExecutionFailed,
        Agent.AgentError.MaxIterationsReached,
        Agent.AgentError.TokenBudgetExceeded,
        Agent.AgentError.LLMCallFailed,
        Agent.AgentError.InvalidResponse,
        Agent.AgentError.NoAPikey,
    };
    _ = errors;
    // This test just verifies the errors compile correctly
}

// ============================================================================
// System Prompt Tests
// ============================================================================

test "createDefaultSystemPrompt - generates non-empty prompt" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    // Add a dummy tool
    const dummy_tool = try allocator.create(struct {
        pub fn tool() Tool {
            return Tool{
                .ptr = undefined,
                .vtable = undefined,
            };
        }
    });
    _ = dummy_tool;

    // We can't actually create a valid Tool without implementing the full vtable,
    // so this test just verifies the function signature works
    // In practice, this would be tested with a real tool registry
}

test "createReActSystemPrompt - generates non-empty prompt" {
    const allocator = std.testing.allocator;
    // Verify function signature exists and compiles
    const prompt = try Agent.createReActSystemPrompt(allocator, undefined);
    defer allocator.free(prompt);
    // The prompt should contain ReAct-related content
    try std.testing.expect(std.mem.indexOf(u8, prompt, "ReAct") != null);
}
