//! Integration tests for agent + tools + memory interactions
//!
//! These tests verify that the components work correctly together,
//! testing the integration points that unit tests cannot cover.
const std = @import("std");
const Agent = @import("agent/agent.zig");
const tools = @import("tools/root.zig");
const ToolRegistry = tools.ToolRegistry;
const ToolResult = tools.ToolResult;
const Tool = tools.Tool;
const MemorySystem = @import("memory.zig").MemorySystem;

// ============================================================================
// Mock Tool Implementations for Testing
// ============================================================================

/// A simple echo tool for testing tool execution
const EchoTool = struct {
    pub const tool_name = "echo";
    pub const tool_description = "Echoes back the input message";
    pub const tool_params =
        \\{"type":"object","properties":{"message":{"type":"string","description":"Message to echo"}},"required":["message"]}
    ;

    fn execute(self: *@This(), allocator: std.mem.Allocator, args: std.json.ObjectMap) !ToolResult {
        _ = self;
        _ = allocator;
        const message = args.get("message") orelse return ToolResult.fail("Missing message parameter");
        const msg_str = switch (message) {
            .string => |s| s,
            else => return ToolResult.fail("message must be a string"),
        };
        return ToolResult.ok(msg_str);
    }
};

/// A calculator tool for testing tool execution with numbers
const CalculatorTool = struct {
    pub const tool_name = "calculate";
    pub const tool_description = "Performs basic arithmetic";
    pub const tool_params =
        \\{"type":"object","properties":{"a":{"type":"number"},"b":{"type":"number"},"operation":{"type":"string","enum":["add","subtract","multiply"]}},"required":["a","b","operation"]}
    ;

    fn execute(self: *@This(), allocator: std.mem.Allocator, args: std.json.ObjectMap) !ToolResult {
        _ = self;
        _ = allocator;

        const a_val = args.get("a") orelse return ToolResult.fail("Missing a parameter");
        const b_val = args.get("b") orelse return ToolResult.fail("Missing b parameter");
        const op_val = args.get("operation") orelse return ToolResult.fail("Missing operation parameter");

        const a = switch (a_val) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return ToolResult.fail("a must be a number"),
        };
        const b = switch (b_val) {
            .integer => |i| @as(f64, @floatFromInt(i)),
            .float => |f| f,
            else => return ToolResult.fail("b must be a number"),
        };
        const op = switch (op_val) {
            .string => |s| s,
            else => return ToolResult.fail("operation must be a string"),
        };

        const result = if (std.mem.eql(u8, op, "add")) a + b else if (std.mem.eql(u8, op, "subtract")) a - b else if (std.mem.eql(u8, op, "multiply")) a * b else return ToolResult.fail("Unknown operation");

        return ToolResult.ok(try std.fmt.allocPrint(allocator, "{d}", .{result}));
    }
};

/// A memory-read tool for testing tool + memory integration
const ReadMemoryTool = struct {
    memory: *MemorySystem,

    pub const tool_name = "read_memory";
    pub const tool_description = "Reads conversation history from memory";
    pub const tool_params =
        \\{"type":"object","properties":{"session_id":{"type":"string","description":"Session ID to read from"}},"required":["session_id"]}
    ;

    fn execute(self: *@This(), allocator: std.mem.Allocator, args: std.json.ObjectMap) !ToolResult {
        const session_id = args.get("session_id") orelse return ToolResult.fail("Missing session_id");
        const sid = switch (session_id) {
            .string => |s| s,
            else => return ToolResult.fail("session_id must be a string"),
        };

        const json = self.memory.getHistoryJSON(allocator, sid) catch return ToolResult.fail("Failed to read memory");
        defer if (json) |j| allocator.free(j);
        return if (json) |j| ToolResult.ok(j) else ToolResult.ok("[]");
    }
};

// ============================================================================
// Helper Functions
// ============================================================================

fn createMockToolRegistry(allocator: std.mem.Allocator) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);

    // Create and register echo tool
    const echo_tool = try allocator.create(EchoTool);
    echo_tool.* = .{};
    try registry.register(tools.toolVTable(EchoTool, echo_tool));

    // Create and register calculator tool
    const calc_tool = try allocator.create(CalculatorTool);
    calc_tool.* = .{};
    try registry.register(tools.toolVTable(CalculatorTool, calc_tool));

    return registry;
}

fn createToolRegistryWithMemory(allocator: std.mem.Allocator, memory: *MemorySystem) !ToolRegistry {
    var registry = ToolRegistry.init(allocator);

    // Create and register echo tool
    const echo_tool = try allocator.create(EchoTool);
    echo_tool.* = .{};
    try registry.register(tools.toolVTable(EchoTool, echo_tool));

    // Create and register memory read tool
    const mem_tool = try allocator.create(ReadMemoryTool);
    mem_tool.* = .{ .memory = memory };
    try registry.register(tools.toolVTable(ReadMemoryTool, mem_tool));

    return registry;
}

// ============================================================================
// Agent + ToolRegistry Integration Tests
// ============================================================================

test "Agent with ToolRegistry - tool registry integration" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    // Verify tools are registered
    try std.testing.expectEqual(@as(usize, 2), registry.count());

    const tools_list = registry.list();
    try std.testing.expectEqual(@as(usize, 2), tools_list.len);

    // Verify tool names
    var tool_names: [2][]const u8 = undefined;
    for (tools_list, 0..) |entry, i| {
        tool_names[i] = entry.spec.name;
    }
    try std.testing.expect(std.mem.containsAtLeast([]const u8, &tool_names, 1, "echo"));
    try std.testing.expect(std.mem.containsAtLeast([]const u8, &tool_names, 1, "calculate"));
}

test "Agent with ToolRegistry - tool execution via registry.call" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    // Test echo tool execution
    const echo_result = try registry.call(allocator, "echo", "{\"message\":\"Hello, World!\"}");
    try std.testing.expect(echo_result.success);
    try std.testing.expectEqualStrings("Hello, World!", echo_result.output);
}

test "Agent with ToolRegistry - calculator tool execution" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    // Test addition
    const add_result = try registry.call(allocator, "calculate", "{\"a\":5,\"b\":3,\"operation\":\"add\"}");
    try std.testing.expect(add_result.success);
    try std.testing.expect(std.mem.indexOf(u8, add_result.output, "8") != null);

    // Test multiplication
    const mul_result = try registry.call(allocator, "calculate", "{\"a\":4,\"b\":7,\"operation\":\"multiply\"}");
    try std.testing.expect(mul_result.success);
    try std.testing.expect(std.mem.indexOf(u8, mul_result.output, "28") != null);
}

test "Agent with ToolRegistry - tool not found returns error" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    const result = registry.call(allocator, "nonexistent_tool", "{}");
    try std.testing.expectError(error.UnknownTool, result);
}

test "Agent with ToolRegistry - tool execution with invalid args" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    // Test echo with missing parameter
    const result = registry.call(allocator, "echo", "{\"wrong_param\":\"value\"}");
    try std.testing.expectError(error.InvalidArguments, result);
}

// ============================================================================
// Agent + Memory Integration Tests
// ============================================================================

test "Agent + Memory - conversation history storage" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create a session and add messages (simulating agent conversation)
    try memory.createSession("test-agent-session");
    try memory.addMessage("test-agent-session", "user", "Hello, agent!");
    try memory.addMessage("test-agent-session", "assistant", "Hello! How can I help you?");
    try memory.addMessage("test-agent-session", "user", "I need help with Zig programming");

    // Verify messages were stored
    const session = memory.getSession("test-agent-session");
    try std.testing.expect(session != null);
    try std.testing.expectEqual(@as(usize, 3), session.?.messages.items.len);

    // Verify message content
    try std.testing.expectEqualStrings("user", session.?.messages.items[0].role);
    try std.testing.expectEqualStrings("Hello, agent!", session.?.messages.items[0].content);
    try std.testing.expectEqualStrings("assistant", session.?.messages.items[1].role);
}

test "Agent + Memory - history retrieval as JSON" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("history-retrieval");
    try memory.addMessage("history-retrieval", "user", "What's the weather?");
    try memory.addMessage("history-retrieval", "assistant", "It's sunny today!");

    const json = try memory.getHistoryJSON(allocator, "history-retrieval");
    defer if (json) |j| allocator.free(j);

    try std.testing.expect(json != null);
    // Verify JSON contains expected content
    try std.testing.expect(std.mem.indexOf(u8, json.?, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "weather") != null);
}

test "Agent + Memory - search across conversations" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Simulate multiple conversations
    try memory.createSession("zig-discussion");
    try memory.addMessage("zig-discussion", "user", "How do I use comptime in Zig?");
    try memory.addMessage("zig-discussion", "assistant", "Comptime is powerful for metaprogramming.");

    try memory.createSession("rust-discussion");
    try memory.addMessage("rust-discussion", "user", "Tell me about Rust ownership.");
    try memory.addMessage("rust-discussion", "assistant", "Ownership prevents data races.");

    try memory.createSession("zig-advanced");
    try memory.addMessage("zig-advanced", "user", "Zig comptime vs C++ templates");

    // Search for "Zig"
    const results = try memory.search(allocator, "Zig");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    // Should find both Zig-related sessions
    try std.testing.expectEqual(@as(usize, 2), results.len);

    // Verify relevance ranking (zig-advanced has "Zig" in single message = 100% match)
    try std.testing.expectEqualStrings("zig-advanced", results[0].session_id);
}

test "Agent + Memory - session persistence simulation" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create multiple agent sessions
    const session_ids = &[_][]const u8{ "session-a", "session-b", "session-c" };
    for (session_ids) |sid| {
        try memory.createSession(sid);
        try memory.addMessage(sid, "user", "Initial message");
    }

    // List all sessions
    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 3), sessions.len);
}

// ============================================================================
// Tool + Memory Integration Tests
// ============================================================================

test "Tool + Memory - read memory tool integration" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    var registry = try createToolRegistryWithMemory(allocator, &memory);
    defer registry.deinit();

    // Add some conversation history
    try memory.createSession("chat-123");
    try memory.addMessage("chat-123", "user", "Hello there");
    try memory.addMessage("chat-123", "assistant", "Hi! How can I help?");

    // Use the read_memory tool
    const result = try registry.call(allocator, "read_memory", "{\"session_id\":\"chat-123\"}");
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "Hello there") != null);
}

test "Tool + Memory - read memory with empty session" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    var registry = try createToolRegistryWithMemory(allocator, &memory);
    defer registry.deinit();

    // Read from non-existent session
    const result = try registry.call(allocator, "read_memory", "{\"session_id\":\"nonexistent\"}");
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("[]", result.output);
}

// ============================================================================
// Agent Lifecycle Integration Tests
// ============================================================================

test "Agent lifecycle - init and deinit with tools" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    const config = Agent.AgentConfig{
        .model = "test-model",
        .max_iterations = 10,
        .system_prompt = "You are a helpful assistant.",
    };

    var agent = Agent.init(allocator, config, &registry);
    defer agent.deinit();

    // Verify agent initialized correctly
    try std.testing.expectEqual(@as(u32, 10), agent.iteration_budget.max_iterations);
    try std.testing.expectEqual(@as(u32, 0), agent.iteration_budget.current);
    try std.testing.expectEqualStrings("test-model", agent.config.model);
}

test "Agent lifecycle - message management" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    const config = Agent.AgentConfig{
        .model = "test-model",
        .max_iterations = 5,
    };

    var agent = Agent.init(allocator, config, &registry);
    defer agent.deinit();

    // Agent should start with empty messages (no system prompt in this config)
    try std.testing.expectEqual(@as(usize, 0), agent.messages.items.len);
}

test "Agent lifecycle - budget management" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    const config = Agent.AgentConfig{
        .model = "test-model",
        .max_iterations = 3,
        .max_tokens = 1000,
    };

    var agent = Agent.init(allocator, config, &registry);
    defer agent.deinit();

    // Verify budgets initialized correctly
    try std.testing.expect(agent.iteration_budget.hasRemaining());
    try std.testing.expectEqual(@as(u32, 3), agent.iteration_budget.remaining());

    try std.testing.expect(agent.token_budget.hasRemaining());
    try std.testing.expectEqual(@as(u32, 1000), agent.token_budget.max_tokens);

    // Simulate iteration
    agent.iteration_budget.tick();
    try std.testing.expectEqual(@as(u32, 2), agent.iteration_budget.remaining());

    // Consume tokens
    agent.token_budget.consume(200);
    try std.testing.expectEqual(@as(u32, 200), agent.token_budget.used_tokens);
}

// ============================================================================
// Error Handling Integration Tests
// ============================================================================

test "Error handling - agent with missing API key" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    const config = Agent.AgentConfig{
        .model = "gpt-4o",
        .api_key = null, // No API key
    };

    var agent = Agent.init(allocator, config, &registry);
    defer agent.deinit();

    // Agent should be initialized but without API key
    try std.testing.expect(!agent.has_api_key);
    try std.testing.expect(agent.client == null);
}

test "Error handling - tool execution errors propagate" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    // Test with invalid JSON arguments
    const result = registry.call(allocator, "echo", "not valid json");
    try std.testing.expectError(error.ParseError, result);
}

test "Error handling - memory system error handling" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Try to add message to non-existent session
    const err = memory.addMessage("nonexistent", "user", "Hello");
    try std.testing.expectError(error.SessionNotFound, err);
}

// ============================================================================
// Complex Integration Scenarios
// ============================================================================

test "Complex scenario - multi-session agent workflow" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Simulate multiple user sessions with the agent
    const workflow = [_]struct { session: []const u8, role: []const u8, content: []const u8 }{
        .{ .session = "user-1-convo", .role = "user", .content = "I need help with my code" },
        .{ .session = "user-1-convo", .role = "assistant", .content = "I'd be happy to help! What language?" },
        .{ .session = "user-1-convo", .role = "user", .content = "I'm working with Zig" },
        .{ .session = "user-2-convo", .role = "user", .content = "What is Rust?" },
        .{ .session = "user-2-convo", .role = "assistant", .content = "Rust is a systems programming language." },
    };

    for (workflow) |msg| {
        try memory.createSession(msg.session);
        try memory.addMessage(msg.session, msg.role, msg.content);
    }

    // Search for conversations about programming
    const results = try memory.search(allocator, "code");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("user-1-convo", results[0].session_id);

    // Verify full conversation retrieval
    const history = try memory.getHistoryJSON(allocator, "user-1-convo");
    defer if (history) |h| allocator.free(h);

    try std.testing.expect(history != null);
    try std.testing.expect(std.mem.indexOf(u8, history.?, "Zig") != null);
}

test "Complex scenario - agent with tool and memory" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    var registry = try createToolRegistryWithMemory(allocator, &memory);
    defer registry.deinit();

    // Simulate storing agent conversation
    try memory.createSession("current-session");
    try memory.addMessage("current-session", "user", "What's in my history?");
    try memory.addMessage("current-session", "assistant", "Let me check...");

    // Use tool to read memory
    const result = try registry.call(allocator, "read_memory", "{\"session_id\":\"current-session\"}");
    try std.testing.expect(result.success);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "history") != null);

    // Add the tool result as assistant message
    try memory.addMessage("current-session", "assistant", result.output);

    // Verify final state
    const session = memory.getSession("current-session");
    try std.testing.expectEqual(@as(usize, 4), session.?.messages.items.len);
}

test "Complex scenario - tool selection based on registry" {
    const allocator = std.testing.allocator;

    var registry = try createMockToolRegistry(allocator);
    defer registry.deinit();

    // Verify we can find and execute the right tool
    const tools_list = registry.list();

    // Find the echo tool
    var echo_tool: ?*const tools.ToolEntry = null;
    for (tools_list) |entry| {
        if (std.mem.eql(u8, entry.spec.name, "echo")) {
            echo_tool = &entry;
            break;
        }
    }

    try std.testing.expect(echo_tool != null);
    try std.testing.expectEqualStrings("echo", echo_tool.?.spec.name);

    // Execute via registry.call for comparison
    const direct_result = try registry.call(allocator, "echo", "{\"message\":\"test\"}");
    try std.testing.expect(direct_result.success);
}
