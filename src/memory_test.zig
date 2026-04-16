//! Memory system tests
const std = @import("std");
const MemorySystem = @import("memory.zig").MemorySystem;
const MemoryBackend = @import("memory.zig").MemoryBackend;

// ============================================================================
// MemorySystem Tests
// ============================================================================

test "MemorySystem.createSession - creates new session" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("session-1");
    try memory.createSession("session-2");

    const sessions = memory.listSessions(allocator) catch unreachable;
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
}

test "MemorySystem.addMessage - adds messages to session" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("chat-1");
    try memory.addMessage("chat-1", "user", "Hello");
    try memory.addMessage("chat-1", "assistant", "Hi there!");
    try memory.addMessage("chat-1", "user", "How are you?");

    const session = memory.getSession("chat-1").?;
    try std.testing.expectEqual(@as(usize, 3), session.messages.items.len);

    try std.testing.expectEqualStrings("user", session.messages.items[0].role);
    try std.testing.expectEqualStrings("Hello", session.messages.items[0].content);
    try std.testing.expectEqualStrings("assistant", session.messages.items[1].role);
    try std.testing.expectEqualStrings("Hi there!", session.messages.items[1].content);
}

test "MemorySystem.getHistoryJSON - returns valid JSON" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("history-test");
    try memory.addMessage("history-test", "user", "Test message");

    const json = try memory.getHistoryJSON(allocator, "history-test");
    defer if (json) |j| allocator.free(j);

    try std.testing.expect(json != null);
    // Verify it's valid JSON with expected structure
    try std.testing.expect(std.mem.indexOf(u8, json.?, "[") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "user") != null);
    try std.testing.expect(std.mem.indexOf(u8, json.?, "Test message") != null);
}

test "MemorySystem.getHistoryJSON - returns null for missing session" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    const json = try memory.getHistoryJSON(allocator, "nonexistent");
    try std.testing.expect(json == null);
}

test "MemorySystem.deleteSession - removes session" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("to-delete");
    try memory.addMessage("to-delete", "user", "Message");

    try std.testing.expect(memory.getSession("to-delete") != null);

    memory.deleteSession("to-delete");

    try std.testing.expect(memory.getSession("to-delete") == null);
}

test "MemorySystem.listSessions - returns all session IDs" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("alpha");
    try memory.createSession("beta");
    try memory.createSession("gamma");

    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 3), sessions.len);
}

test "MemorySystem.search - finds matching sessions" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create sessions with different content
    try memory.createSession("coding");
    try memory.addMessage("coding", "user", "How do I write a recursive function in Zig?");
    try memory.addMessage("coding", "assistant", "Here's how to write recursion...");

    try memory.createSession("cooking");
    try memory.addMessage("cooking", "user", "How do I make pasta?");

    try memory.createSession("gaming");
    try memory.addMessage("gaming", "user", "What's the best video game ever?");

    // Search for "zig"
    const results = try memory.search(allocator, "Zig");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("coding", results[0].session_id);
}

test "MemorySystem.search - case insensitive" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("test");
    try memory.addMessage("test", "user", "Important DATA");

    // Search with different case
    const results_lower = try memory.search(allocator, "important");
    defer {
        for (results_lower) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results_lower);
    }

    try std.testing.expectEqual(@as(usize, 1), results_lower.len);

    const results_upper = try memory.search(allocator, "IMPORTANT");
    defer {
        for (results_upper) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results_upper);
    }

    try std.testing.expectEqual(@as(usize, 1), results_upper.len);
}

test "MemorySystem.search - no matches returns empty" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("test");
    try memory.addMessage("test", "user", "Hello");

    const results = try memory.search(allocator, "nonexistent-query-xyz");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "MemorySystem.searchJSON - returns valid JSON" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("json-search");
    try memory.addMessage("json-search", "user", "Searchable content");

    const json = try memory.searchJSON(allocator, "Searchable");
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "results") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "count") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "json-search") != null);
}

test "MemorySystem.getRecent - returns sessions by update time" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create sessions - oldest first
    try memory.createSession("oldest");
    try memory.addMessage("oldest", "user", "Old message");

    try memory.createSession("newest");
    try memory.addMessage("newest", "user", "New message");

    const results = try memory.getRecent(allocator, 10);
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 2), results.len);
    // Newest should be first
    try std.testing.expectEqualStrings("newest", results[0].session_id);
}

// ============================================================================
// MemoryBackend Tests
// ============================================================================

test "MemoryBackend.init - creates in-memory backend" {
    const allocator = std.testing.allocator;
    var backend = try MemoryBackend.init(allocator, .in_memory, null);
    defer backend.deinit();

    try backend.createSession("test");
    try backend.addMessage("test", "user", "Hello");

    const history = try backend.getHistoryJSON(allocator, "test");
    defer if (history) |h| allocator.free(h);

    try std.testing.expect(history != null);
}

test "MemoryBackend.listSessions - lists sessions" {
    const allocator = std.testing.allocator;
    var backend = try MemoryBackend.init(allocator, .in_memory, null);
    defer backend.deinit();

    try backend.createSession("s1");
    try backend.createSession("s2");

    const sessions = try backend.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 2), sessions.len);
}

test "MemoryBackend.deleteSession - removes session" {
    const allocator = std.testing.allocator;
    var backend = try MemoryBackend.init(allocator, .in_memory, null);
    defer backend.deinit();

    try backend.createSession("to-delete");
    backend.deleteSession("to-delete");

    const sessions = try backend.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}
