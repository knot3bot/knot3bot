const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

// Re-export SqliteMemorySystem for external use
pub const SqliteMemorySystem = @import("memory/sqlite.zig").SqliteMemorySystem;
pub const SqlError = @import("memory/sqlite.zig").SqlError;

/// Memory System for session storage with in-memory backend
pub const MemorySystem = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),

    pub const Session = struct {
        id: []const u8,
        messages: std.ArrayList(Message),
        created_at: i64,
        updated_at: i64,

        pub const Message = struct {
            role: []const u8,
            content: []const u8,
            timestamp: i64,
        };
    };

    /// Initialize memory system
    pub fn init(allocator: std.mem.Allocator) MemorySystem {
        return .{
            .allocator = allocator,
            .sessions = std.StringHashMap(Session).init(allocator),
        };
    }

    /// Clean up memory system
    pub fn deinit(self: *MemorySystem) void {
        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            var session = entry.value_ptr;
            for (session.messages.items) |msg| {
                self.allocator.free(msg.role);
                self.allocator.free(msg.content);
            }
            session.messages.deinit(self.allocator);
            self.allocator.free(session.id);
        }
        self.sessions.deinit();
    }

    /// Create a new session
    pub fn createSession(self: *MemorySystem, session_id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, session_id);
        errdefer self.allocator.free(id_copy);

        const session = Session{
            .id = id_copy,
            .messages = .empty,
            .created_at = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds(),
            .updated_at = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds(),
        };

        try self.sessions.put(id_copy, session);
    }

    /// Get session by ID
    pub fn getSession(self: *MemorySystem, session_id: []const u8) ?*Session {
        return self.sessions.getPtr(session_id);
    }

    /// Add message to session
    pub fn addMessage(self: *MemorySystem, session_id: []const u8, role: []const u8, content: []const u8) !void {
        var session = self.sessions.getPtr(session_id) orelse return error.SessionNotFound;

        const role_copy = try self.allocator.dupe(u8, role);
        errdefer self.allocator.free(role_copy);

        const content_copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_copy);

        try session.messages.append(self.allocator, .{
            .role = role_copy,
            .content = content_copy,
            .timestamp = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds(),
        });

        session.updated_at = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds();
    }

    /// Get session history as JSON
    pub fn getHistoryJSON(self: *MemorySystem, allocator: std.mem.Allocator, session_id: []const u8) !?[]const u8 {
        const session = self.sessions.get(session_id) orelse return null;

        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(allocator);
        const writer = list.writer(allocator);

        try writer.writeAll("[");
        for (session.messages.items, 0..) |msg, i| {
            if (i > 0) try writer.writeAll(",");
            try writer.print(
                "{{\"role\":\"{s}\",\"content\":\"{s}\",\"timestamp\":{d}}}",
                .{ msg.role, msg.content, msg.timestamp },
            );
        }
        try writer.writeAll("]");

        return try list.toOwnedSlice(allocator);
    }

    /// Delete session
    pub fn deleteSession(self: *MemorySystem, session_id: []const u8) void {
        if (self.sessions.fetchRemove(session_id)) |kv| {
            var session = kv.value;
            for (session.messages.items) |msg| {
                self.allocator.free(msg.role);
                self.allocator.free(msg.content);
            }
            session.messages.deinit(self.allocator);
            self.allocator.free(session.id);
        }
    }

    /// List all session IDs
    pub fn listSessions(self: *MemorySystem, allocator: std.mem.Allocator) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (list.items) |id| {
                allocator.free(id);
            }
            list.deinit(allocator);
        }

        var it = self.sessions.keyIterator();
        while (it.next()) |key| {
            const id_copy = try allocator.dupe(u8, key.*);
            try list.append(allocator, id_copy);
        }

        return try list.toOwnedSlice(allocator);
    }

    /// Search result entry
    pub const SearchResult = struct {
        session_id: []const u8,
        relevance_score: f32,
        match_count: usize,
        last_message: []const u8,
    };

    /// Search sessions by keyword query (hybrid search - keyword matching)
    pub fn search(self: *MemorySystem, allocator: std.mem.Allocator, query: []const u8) ![]SearchResult {
        var results: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (results.items) |r| {
                allocator.free(r.session_id);
                allocator.free(r.last_message);
            }
            results.deinit(allocator);
        }

        const query_lower = try allocator.dupe(u8, query);
        defer allocator.free(query_lower);
        for (query_lower) |*char| char.* = std.ascii.toLower(char.*);

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr;
            var match_count: usize = 0;
            var last_msg: ?[]const u8 = null;

            for (session.messages.items) |msg| {
                const content_lower = try allocator.dupe(u8, msg.content);
                defer allocator.free(content_lower);
                for (content_lower) |*byte| byte.* = std.ascii.toLower(byte.*);

                if (std.mem.indexOf(u8, content_lower, query_lower) != null) {
                    match_count += 1;
                }
                last_msg = msg.content;
            }

            if (match_count > 0) {
                const id_copy = try allocator.dupe(u8, session.id);
                const last_copy = if (last_msg) |lm| try allocator.dupe(u8, lm) else "".*;
                const score = @as(f32, @floatFromInt(match_count)) / @as(f32, @floatFromInt(session.messages.items.len));
                try results.append(allocator, .{
                    .session_id = id_copy,
                    .relevance_score = score,
                    .match_count = match_count,
                    .last_message = last_copy,
                });
            }
        }

        // Sort by relevance score descending
        std.sort.sort(SearchResult, results.items, {}, struct {
            fn lessThan(_: void, a: SearchResult, b: SearchResult) bool {
                return a.relevance_score > b.relevance_score;
            }
        }.lessThan);

        return try results.toOwnedSlice(allocator);
    }

    /// Get recent sessions sorted by last update time
    pub fn getRecent(self: *MemorySystem, allocator: std.mem.Allocator, limit: usize) ![]SearchResult {
        var sessions_list: std.ArrayList(struct { id: []const u8, updated: i64, last_msg: []const u8 }) = .empty;
        defer {
            for (sessions_list.items) |s| {
                allocator.free(s.id);
                allocator.free(s.last_msg);
            }
            sessions_list.deinit(allocator);
        }

        var it = self.sessions.iterator();
        while (it.next()) |entry| {
            const session = entry.value_ptr;
            const id_copy = try allocator.dupe(u8, session.id);
            const last_msg = if (session.messages.items.len > 0)
                try allocator.dupe(u8, session.messages.items[session.messages.items.len - 1].content)
            else
                try allocator.dupe(u8, "");
            try sessions_list.append(allocator, .{
                .id = id_copy,
                .updated = session.updated_at,
                .last_msg = last_msg,
            });
        }

        // Sort by updated_at descending
        std.sort.sort(struct { id: []const u8, updated: i64, last_msg: []const u8 }, sessions_list.items, {}, struct {
            fn lessThan(_: void, a: @TypeOf(sessions_list.items[0]), b: @TypeOf(sessions_list.items[0])) bool {
                return a.updated > b.updated;
            }
        }.lessThan);

        const result_count = @min(limit, sessions_list.items.len);
        var results: std.ArrayList(SearchResult) = .empty;
        errdefer {
            for (results.items) |r| {
                allocator.free(r.session_id);
                allocator.free(r.last_message);
            }
            results.deinit(allocator);
        }

        for (sessions_list.items[0..result_count]) |s| {
            try results.append(allocator, .{
                .session_id = try allocator.dupe(u8, s.id),
                .relevance_score = 0.0,
                .match_count = 0,
                .last_message = try allocator.dupe(u8, s.last_msg),
            });
        }

        return try results.toOwnedSlice(allocator);
    }

    /// Get search results as JSON
    pub fn searchJSON(self: *MemorySystem, allocator: std.mem.Allocator, query: []const u8) ![]const u8 {
        const results = try self.search(allocator, query);
        defer {
            for (results) |r| {
                allocator.free(r.session_id);
                allocator.free(r.last_message);
            }
            allocator.free(results);
        }

        var output: std.ArrayList(u8) = .empty;
        defer output.deinit(allocator);

        try output.appendSlice(allocator, "{\"results\":[");
        for (results, 0..) |r, i| {
            if (i > 0) try output.appendSlice(allocator, ",");
            try output.appendSlice(allocator, "{\"session_id\":\"");
            try output.appendSlice(allocator, r.session_id);
            try output.appendSlice(allocator, "\",\"relevance_score\":");
            try output.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{d}", .{r.relevance_score}));
            try output.appendSlice(allocator, ",\"match_count\":");
            try output.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{}", .{r.match_count}));
            try output.appendSlice(allocator, ",\"last_message\":\"");
            try output.appendSlice(allocator, r.last_message);
            try output.appendSlice(allocator, "\"}");
        }
        try output.appendSlice(allocator, "],\"count\":");
        try output.appendSlice(allocator, try std.fmt.allocPrint(allocator, "{}", .{results.len}));
        try output.appendSlice(allocator, "}");

        return try output.toOwnedSlice(allocator);
    }
};

test "MemorySystem basic operations" {
    const allocator = std.testing.allocator;

    var memory = MemorySystem.init(allocator);
    defer memory.deinit();

    // Create session
    try memory.createSession("test-session");

    // Add messages
    try memory.addMessage("test-session", "user", "Hello");
    try memory.addMessage("test-session", "assistant", "Hi there!");

    // Get session
    const session = memory.getSession("test-session");
    try std.testing.expect(session != null);
    try std.testing.expectEqual(@as(usize, 2), session.?.messages.items.len);

    // Get history
    const history = try memory.getHistoryJSON(allocator, "test-session");
    defer if (history) |h| allocator.free(h);
    try std.testing.expect(history != null);
}

/// MemoryBackend provides a unified interface for different memory backends
pub const MemoryBackend = struct {
    pub const BackendType = enum {
        in_memory,
        sqlite,
        openviking,
    };

    backend_type: BackendType,
    // Use unaligned union to avoid alignment issues with different struct sizes
    data: union(BackendType) {
        in_memory: *MemorySystem,
        sqlite: *SqliteMemorySystem,
        openviking: void,
    },

    pub fn init(allocator: std.mem.Allocator, backend_type: BackendType, path: ?[]const u8) !MemoryBackend {
        switch (backend_type) {
            .in_memory => {
                const ms = try allocator.create(MemorySystem);
                ms.* = MemorySystem.init(allocator);
                return MemoryBackend{
                    .backend_type = backend_type,
                    .data = .{ .in_memory = ms },
                };
            },
            .sqlite => {
                const db_path = path orelse return error.InvalidPath;
                const sqlite = try allocator.create(SqliteMemorySystem);
                sqlite.* = try SqliteMemorySystem.init(allocator, db_path);
                return MemoryBackend{
                    .backend_type = backend_type,
                    .data = .{ .sqlite = sqlite },
                };
            },
            .openviking => {
                return MemoryBackend{
                    .backend_type = backend_type,
                    .data = .{ .openviking = {} },
                };
            },
        }
    }

    pub fn deinit(self: *MemoryBackend) void {
        switch (self.data) {
            .in_memory => |ms| ms.deinit(),
            .sqlite => |sqlite| sqlite.deinit(),
            .openviking => {},
        }
    }

    pub fn createSession(self: *MemoryBackend, session_id: []const u8) !void {
        switch (self.data) {
            .in_memory => |ms| return ms.createSession(session_id),
            .sqlite => |sqlite| return sqlite.createSession(session_id),
            .openviking => return error.NotImplemented,
        }
    }

    pub fn addMessage(self: *MemoryBackend, session_id: []const u8, role: []const u8, content: []const u8) !void {
        switch (self.data) {
            .in_memory => |ms| return ms.addMessage(session_id, role, content),
            .sqlite => |sqlite| return sqlite.addMessage(session_id, role, content),
            .openviking => return error.NotImplemented,
        }
    }

    pub fn deleteSession(self: *MemoryBackend, session_id: []const u8) void {
        switch (self.data) {
            .in_memory => |ms| ms.deleteSession(session_id),
            .sqlite => |sqlite| sqlite.deleteSession(session_id) catch {},
            .openviking => {},
        }
    }

    pub fn getHistoryJSON(self: *MemoryBackend, allocator: std.mem.Allocator, session_id: []const u8) !?[]const u8 {
        switch (self.data) {
            .in_memory => |ms| return ms.getHistoryJSON(allocator, session_id),
            .sqlite => |sqlite| {
                const result = try sqlite.getHistoryJSON(allocator, session_id);
                return result;
            },
            .openviking => return error.NotImplemented,
        }
    }

    pub fn listSessions(self: *MemoryBackend, allocator: std.mem.Allocator) ![][]const u8 {
        switch (self.data) {
            .in_memory => |ms| return ms.listSessions(allocator),
            .sqlite => |sqlite| return sqlite.listSessions(allocator),
            .openviking => return error.NotImplemented,
        }
    }
};
