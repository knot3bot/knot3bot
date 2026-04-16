//! Memory System Stress Tests
//!
//! Tests for memory system under high load conditions,
//! including large sessions, many concurrent sessions,
//! and edge cases with large content.
const std = @import("std");
const MemorySystem = @import("memory.zig").MemorySystem;
const MemoryBackend = @import("memory.zig").MemoryBackend;

// ============================================================================
// Large Session Tests
// ============================================================================

test "Memory pressure - session with 1000 messages" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("large-session");

    // Add 1000 messages
    for (0..1000) |i| {
        const content = try std.fmt.allocPrint(allocator, "Message {d} with some content here", .{i});
        defer allocator.free(content);
        try memory.addMessage("large-session", if (i % 2 == 0) "user" else "assistant", content);
    }

    const session = memory.getSession("large-session");
    try std.testing.expect(session != null);
    try std.testing.expectEqual(@as(usize, 1000), session.?.messages.items.len);
}

test "Memory pressure - session with long content (10KB)" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("long-content");

    // Create 10KB of content
    var large_content: [10240]u8 = undefined;
    for (large_content[0..], 0..) |*byte, i| {
        byte.* = @truncate(@as(u8, ('A' + @as(u8, @intCast(i % 26)))));
    }

    try memory.addMessage("long-content", "user", large_content[0..]);

    const session = memory.getSession("long-content");
    try std.testing.expectEqual(@as(usize, 10240), session.?.messages.items[0].content.len);
}

test "Memory pressure - session with very long content (100KB)" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("very-long");

    // Create 100KB of content
    var very_large: [102400]u8 = undefined;
    for (very_large[0..], 0..) |*byte, i| {
        byte.* = @truncate(@as(u8, ('0' + @as(u8, @intCast(i % 10)))));
    }

    try memory.addMessage("very-long", "user", very_large[0..]);

    const session = memory.getSession("very-long");
    try std.testing.expectEqual(@as(usize, 102400), session.?.messages.items[0].content.len);
}

// ============================================================================
// Many Sessions Tests
// ============================================================================

test "Memory pressure - 100 concurrent sessions" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create 100 sessions
    for (0..100) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "session-{d}", .{i});
        defer allocator.free(session_id);
        try memory.createSession(session_id);
        try memory.addMessage(session_id, "user", "Initial message");
    }

    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 100), sessions.len);
}

test "Memory pressure - 500 sessions with messages" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create 500 sessions with 5 messages each
    for (0..500) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "sess-{d}", .{i});
        defer allocator.free(session_id);
        try memory.createSession(session_id);

        for (0..5) |j| {
            const msg = try std.fmt.allocPrint(allocator, "msg-{d}-{d}", .{ i, j });
            defer allocator.free(msg);
            try memory.addMessage(session_id, if (j % 2 == 0) "user" else "assistant", msg);
        }
    }

    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 500), sessions.len);
}

// ============================================================================
// Search Performance Tests
// ============================================================================

test "Memory pressure - search with 1000 sessions" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create sessions with searchable content
    for (0..1000) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "searchable-{d}", .{i});
        defer allocator.free(session_id);
        try memory.createSession(session_id);

        // Add message with keyword
        if (i % 10 == 0) {
            try memory.addMessage(session_id, "user", "This message contains the keyword zig");
        } else {
            try memory.addMessage(session_id, "user", "Regular message content");
        }
    }

    // Search for keyword
    const results = try memory.search(allocator, "zig");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    // Should find ~100 sessions (every 10th)
    try std.testing.expect(results.len >= 50);
}

test "Memory pressure - search with large content" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("large-search");
    var content: [50000]u8 = undefined;
    for (content[0..], 0..) |*byte, i| {
        byte.* = @truncate(@as(u8, ('a' + @as(u8, @intCast(i % 26)))));
    }
    // Insert search term multiple times
    @memcpy(content[1000..1004], "test");
    @memcpy(content[25000..25004], "test");
    @memcpy(content[45000..45004], "test");

    try memory.addMessage("large-search", "user", content[0..]);

    const results = try memory.search(allocator, "test");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    try std.testing.expectEqual(@as(usize, 1), results.len);
}

// ============================================================================
// History JSON Tests with Large Data
// ============================================================================

test "Memory pressure - getHistoryJSON with large session" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("json-large");

    // Add messages with varied content
    for (0..100) |i| {
        const msg = try std.fmt.allocPrint(allocator, "Detailed message {d} with substantial content", .{i});
        defer allocator.free(msg);
        try memory.addMessage("json-large", if (i % 2 == 0) "user" else "assistant", msg);
    }

    const json = try memory.getHistoryJSON(allocator, "json-large");
    defer if (json) |j| allocator.free(j);

    try std.testing.expect(json != null);
    try std.testing.expect(json.?.len > 5000); // Should be substantial JSON
}

// ============================================================================
// Session Lifecycle Stress
// ============================================================================

test "Memory pressure - rapid session create/delete" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Rapidly create and delete sessions
    for (0..50) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "temp-{d}", .{i});
        defer allocator.free(session_id);
        try memory.createSession(session_id);
        try memory.addMessage(session_id, "user", "Temporary");
    }

    // Delete all
    for (0..50) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "temp-{d}", .{i});
        defer allocator.free(session_id);
        memory.deleteSession(session_id);
    }

    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 0), sessions.len);
}

test "Memory pressure - session update cycles" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("updating");

    // Multiple update cycles
    for (0..100) |i| {
        const msg = try std.fmt.allocPrint(allocator, "Update {d}", .{i});
        defer allocator.free(msg);
        try memory.addMessage("updating", "user", msg);
    }

    const session = memory.getSession("updating");
    try std.testing.expectEqual(@as(usize, 100), session.?.messages.items.len);

    // Verify timestamps are updated
    try std.testing.expect(session.?.updated_at >= session.?.created_at);
}

// ============================================================================
// Unicode and Special Content Tests
// ============================================================================

test "Memory stress - unicode content (CJK)" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("unicode");
    try memory.addMessage("unicode", "user", "你好世界Hello world");
    try memory.addMessage("unicode", "assistant", "こんにちは世界");
    try memory.addMessage("unicode", "user", "مرحبا بالعالم");

    const session = memory.getSession("unicode");
    try std.testing.expectEqual(@as(usize, 3), session.?.messages.items.len);
}

test "Memory stress - special characters" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("special");
    try memory.addMessage("special", "user", "Line1\nLine2\tTabbed\"Quoted\"Backslash\\");
    try memory.addMessage("special", "assistant", "Emoji: 🎉🔥💻 | Code: `const x = 1;`");

    const session = memory.getSession("special");
    try std.testing.expectEqual(@as(usize, 2), session.?.messages.items.len);
}

test "Memory stress - empty content" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("empty");
    try memory.addMessage("empty", "user", "");

    const session = memory.getSession("empty");
    try std.testing.expectEqualStrings("", session.?.messages.items[0].content);
}

// ============================================================================
// MemoryBackend Stress Tests
// ============================================================================

test "MemoryBackend - stress with in-memory backend" {
    const allocator = std.testing.allocator;
    var backend = try MemoryBackend.init(allocator, .in_memory, null);
    defer backend.deinit();

    // Create multiple sessions
    for (0..100) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "backend-sess-{d}", .{i});
        defer allocator.free(session_id);
        try backend.createSession(session_id);

        for (0..10) |j| {
            const msg = try std.fmt.allocPrint(allocator, "Message {d}-{d}", .{ i, j });
            defer allocator.free(msg);
            try backend.addMessage(session_id, "user", msg);
        }
    }

    const sessions = try backend.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 100), sessions.len);
}

test "MemoryBackend - search with many sessions" {
    const allocator = std.testing.allocator;
    var backend = try MemoryBackend.init(allocator, .in_memory, null);
    defer backend.deinit();

    // Create sessions with search terms
    for (0..200) |i| {
        const session_id = try std.fmt.allocPrint(allocator, "s-{d}", .{i});
        defer allocator.free(session_id);
        try backend.createSession(session_id);

        const content = if (i % 5 == 0)
            try std.fmt.allocPrint(allocator, "Contains keyword for search", .{})
        else
            try std.fmt.allocPrint(allocator, "Regular content {d}", .{i});
        try backend.addMessage(session_id, "user", content);
        allocator.free(content);
    }

    const results = try backend.search(allocator, "keyword");
    defer {
        for (results) |r| {
            allocator.free(r.session_id);
            allocator.free(r.last_message);
        }
        allocator.free(results);
    }

    try std.testing.expect(results.len >= 20);
}

// ============================================================================
// Concurrent Access Simulation
// ============================================================================

test "Memory simulation - interleaved session operations" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Simulate interleaved operations on multiple sessions
    const session_ids = &[_][]const u8{ "a", "b", "c", "d", "e" };

    // Round 1: Create all
    for (session_ids) |sid| {
        try memory.createSession(sid);
    }

    // Round 2: Add messages (interleaved)
    for (session_ids, 0..) |sid, round| {
        for (0..10) |i| {
            const msg = try std.fmt.allocPrint(allocator, "Round{d}-Msg{d}", .{ round, i });
            defer allocator.free(msg);
            try memory.addMessage(sid, "user", msg);
        }
    }

    // Verify all sessions have correct message counts
    for (session_ids) |sid| {
        const session = memory.getSession(sid);
        try std.testing.expectEqual(@as(usize, 10), session.?.messages.items.len);
    }
}

test "Memory simulation - session migration pattern" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Simulate session being passed between contexts
    try memory.createSession("migrating");
    try memory.addMessage("migrating", "user", "Context A: Initial request");

    // Transfer to another context
    try memory.addMessage("migrating", "assistant", "Context A: Working...");
    try memory.addMessage("migrating", "user", "Context B: Continuing work");

    // Context B continues
    try memory.addMessage("migrating", "assistant", "Context B: Taking over");
    try memory.addMessage("migrating", "user", "Context C: Final input");

    const session = memory.getSession("migrating");
    try std.testing.expectEqual(@as(usize, 5), session.?.messages.items.len);

    // Verify conversation flow
    try std.testing.expect(std.mem.indexOf(u8, session.?.messages.items[1].content, "Context A") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.?.messages.items[3].content, "Context B") != null);
}

// ============================================================================
// Edge Cases and Boundaries
// ============================================================================

test "Edge case - session ID boundaries" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Very short ID
    try memory.createSession("x");
    try memory.addMessage("x", "user", "Short ID");

    // Very long ID
    const long_id = try allocator.alloc(u8, 1000);
    defer allocator.free(long_id);
    @memset(long_id, 'i');
    try memory.createSession(long_id);

    // Unicode ID
    try memory.createSession("会话123");

    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 3), sessions.len);
}

test "Edge case - message size boundary" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    try memory.createSession("size-test");

    // Just under 1MB
    const near_limit = try allocator.alloc(u8, 900_000);
    defer allocator.free(near_limit);
    @memset(near_limit, 'x');

    try memory.addMessage("size-test", "user", near_limit);

    const session = memory.getSession("size-test");
    try std.testing.expectEqual(@as(usize, 900_000), session.?.messages.items[0].content.len);
}

test "Edge case - delete during iteration" {
    const allocator = std.testing.allocator;
    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create sessions
    for (0..20) |i| {
        const sid = try std.fmt.allocPrint(allocator, "del-{d}", .{i});
        defer allocator.free(sid);
        try memory.createSession(sid);
    }

    // Delete every other session
    for (0..20) |i| {
        if (i % 2 == 0) {
            const sid = try std.fmt.allocPrint(allocator, "del-{d}", .{i});
            defer allocator.free(sid);
            memory.deleteSession(sid);
        }
    }

    const sessions = try memory.listSessions(allocator);
    defer {
        for (sessions) |s| allocator.free(s);
        allocator.free(sessions);
    }

    try std.testing.expectEqual(@as(usize, 10), sessions.len);
}
