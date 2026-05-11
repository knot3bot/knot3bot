const std = @import("std");

const c = @cImport(@cInclude("sqlite3.h"));

// SQLITE_STATIC - we use this but MUST ensure strings are heap-allocated
// before passing to SQLite. See heapAllocString() helper.
const SQLITE_STATIC: ?*const fn (?*anyopaque) callconv(.c) void = null;
const SQLITE_TRANSIENT: ?*const fn (?*anyopaque) callconv(.c) void = SQLITE_STATIC;

pub const SqlError = error{
    DatabaseOpenFailed,
    PrepareFailed,
    StepFailed,
    BindFailed,
    ColumnNotFound,
    SessionNotFound,
    FileWriteFailed,
    FileReadFailed,
    OutOfMemory,
};

pub const SqliteMemorySystem = struct {
    allocator: std.mem.Allocator,
    db: ?*c.sqlite3,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) SqlError!SqliteMemorySystem {
        var db: ?*c.sqlite3 = null;

        // Create null-terminated string for C API
        const db_path_nt = try allocator.alloc(u8, db_path.len + 1);
        errdefer allocator.free(db_path_nt);
        @memcpy(db_path_nt[0..db_path.len], db_path);
        db_path_nt[db_path.len] = 0;

        const rc = c.sqlite3_open(db_path_nt.ptr, &db);
        if (rc != c.SQLITE_OK) {
            allocator.free(db_path_nt);
            if (db) |d| _ = c.sqlite3_close(d);
            return SqlError.DatabaseOpenFailed;
        }

        const self = SqliteMemorySystem{
            .allocator = allocator,
            .db = db,
        };

        allocator.free(db_path_nt);

        try self.createTables();
        return self;
    }

    fn createTables(self: *const SqliteMemorySystem) SqlError!void {
        const create_sessions =
            \\CREATE TABLE IF NOT EXISTS sessions (
            \\    id TEXT PRIMARY KEY,
            \\    created_at INTEGER NOT NULL,
            \\    updated_at INTEGER NOT NULL
            \\)
        ;

        const create_messages =
            \\CREATE TABLE IF NOT EXISTS messages (
            \\    id INTEGER PRIMARY KEY AUTOINCREMENT,
            \\    session_id TEXT NOT NULL,
            \\    role TEXT NOT NULL,
            \\    content TEXT NOT NULL,
            \\    importance REAL DEFAULT 0.5,
            \\    timestamp INTEGER NOT NULL,
            \\    FOREIGN KEY (session_id) REFERENCES sessions(id) ON DELETE CASCADE
            \\)
        ;

        // FTS5 virtual table for full-text search across messages
        const create_fts =
            \\CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(
            \\    content,
            \\    session_id,
            \\    content_rowid='id',
            \\    content='messages'
            \\)
        ;

        // Triggers to keep FTS in sync with messages table
        const create_fts_insert =
            \\CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
            \\    INSERT INTO messages_fts(rowid, content, session_id) VALUES (new.id, new.content, new.session_id);
            \\END
        ;

        const create_fts_delete =
            \\CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
            \\    INSERT INTO messages_fts(messages_fts, rowid, content, session_id) VALUES('delete', old.id, old.content, old.session_id);
            \\END
        ;

        const create_fts_update =
            \\CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
            \\    INSERT INTO messages_fts(messages_fts, rowid, content, session_id) VALUES('delete', old.id, old.content, old.session_id);
            \\    INSERT INTO messages_fts(rowid, content, session_id) VALUES (new.id, new.content, new.session_id);
            \\END
        ;

        try self.exec(create_sessions);
        try self.exec(create_messages);
        try self.exec(create_fts);
        try self.exec(create_fts_insert);
        try self.exec(create_fts_delete);
        try self.exec(create_fts_update);
    }

    fn exec(self: *const SqliteMemorySystem, sql: [:0]const u8) SqlError!void {
        var err_msg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql, null, null, &err_msg);
        if (rc != c.SQLITE_OK) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return SqlError.StepFailed;
        }
    }

    pub const SearchResult = struct {
        session_id: []const u8,
        content: []const u8,
        relevance_score: f64,
        timestamp: i64,
        importance: f32,
    };

    /// Full-text search across all messages with FTS5 ranking.
    /// Returns results sorted by relevance (bm25).
    pub fn searchMessages(self: *SqliteMemorySystem, allocator: std.mem.Allocator, query: []const u8, limit: u32) SqlError![]SearchResult {
        const sql =
            \\SELECT m.session_id, m.content, m.timestamp, m.importance, rank
            \\FROM messages_fts f
            \\JOIN messages m ON f.rowid = m.id
            \\WHERE messages_fts MATCH ?
            \\ORDER BY rank
            \\LIMIT ?
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const query_heap = try self.heapAllocString(query);
        defer self.allocator.free(query_heap);
        _ = c.sqlite3_bind_text(stmt, 1, query_heap.ptr, -1, SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int64(stmt, 2, @intCast(limit));

        var results = std.ArrayList(SearchResult).initCapacity(allocator, limit) catch return SqlError.OutOfMemory;
        errdefer {
            for (results.items) |r| {
                allocator.free(r.session_id);
                allocator.free(r.content);
            }
            results.deinit(allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const session_id_ptr = c.sqlite3_column_text(stmt, 0);
            const content_ptr = c.sqlite3_column_text(stmt, 1);
            const timestamp = c.sqlite3_column_int64(stmt, 2);
            const importance = @as(f32, @floatCast(c.sqlite3_column_double(stmt, 3)));
            const rank = c.sqlite3_column_int64(stmt, 4);

            if (session_id_ptr) |sid| {
                const session_id = try allocator.dupe(u8, std.mem.sliceTo(sid, 0));
                errdefer allocator.free(session_id);
                const content = try allocator.dupe(u8, std.mem.sliceTo(content_ptr orelse "", 0));
                results.append(SearchResult{
                    .session_id = session_id,
                    .content = content,
                    .relevance_score = @as(f64, @floatFromInt(rank)),
                    .timestamp = timestamp,
                    .importance = importance,
                }) catch SqlError.OutOfMemory;
            }
        }
        return results.toOwnedSlice(allocator);
    }

    /// Update importance score for a message.
    pub fn setImportance(self: *SqliteMemorySystem, message_id: i64, importance: f32) SqlError!void {
        const sql = "UPDATE messages SET importance = ? WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_double(stmt, 1, @floatCast(importance));
        _ = c.sqlite3_bind_int64(stmt, 2, message_id);
        if (c.sqlite3_step(stmt) != c.SQLITE_DONE) return SqlError.StepFailed;
    }

    /// Get high-importance messages across sessions for knowledge retention.
    pub fn getImportantMessages(self: *SqliteMemorySystem, allocator: std.mem.Allocator, min_importance: f32, limit: u32) SqlError![]SearchResult {
        const sql = "SELECT session_id, content, timestamp, importance FROM messages WHERE importance >= ? ORDER BY importance DESC LIMIT ?";
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        _ = c.sqlite3_bind_double(stmt, 1, min_importance);
        _ = c.sqlite3_bind_int64(stmt, 2, limit);

        var results = std.ArrayList(SearchResult).initCapacity(allocator, limit) catch return SqlError.OutOfMemory;
        errdefer {
            for (results.items) |r| {
                allocator.free(r.session_id);
                allocator.free(r.content);
            }
            results.deinit(allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const session_id_ptr = c.sqlite3_column_text(stmt, 0);
            const content_ptr = c.sqlite3_column_text(stmt, 1);
            const timestamp = c.sqlite3_column_int64(stmt, 2);
            const importance = @as(f32, @floatCast(c.sqlite3_column_double(stmt, 3)));

            if (session_id_ptr) |sid| {
                const session_id = try allocator.dupe(u8, std.mem.sliceTo(sid, 0));
                errdefer allocator.free(session_id);
                const content = try allocator.dupe(u8, std.mem.sliceTo(content_ptr orelse "", 0));
                results.append(SearchResult{
                    .session_id = session_id,
                    .content = content,
                    .relevance_score = importance,
                    .timestamp = timestamp,
                    .importance = importance,
                }) catch SqlError.OutOfMemory;
            }
        }
        return results.toOwnedSlice(allocator);
    }

    pub fn deinit(self: *SqliteMemorySystem) void {
        if (self.db) |db| {
            _ = c.sqlite3_close(db);
        }
    }

    /// Ensure a string is heap-allocated and null-terminated for SQLite
    fn heapAllocString(self: *SqliteMemorySystem, s: []const u8) SqlError![]u8 {
        const result = try self.allocator.alloc(u8, s.len + 1);
        @memcpy(result[0..s.len], s);
        result[s.len] = 0;
        return result;
    }

    pub fn createSession(self: *SqliteMemorySystem, session_id: []const u8) SqlError!void {
        const sql = "INSERT INTO sessions (id, created_at, updated_at) VALUES (?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const timestamp = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds();

        // Use -1 so SQLite copies immediately, avoiding use-after-free
        const session_id_heap = try self.heapAllocString(session_id);
        defer self.allocator.free(session_id_heap);
        _ = c.sqlite3_bind_text(stmt, 1, session_id_heap.ptr, -1, SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int64(stmt, 2, timestamp);
        _ = c.sqlite3_bind_int64(stmt, 3, timestamp);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return SqlError.StepFailed;
    }

    pub fn addMessage(self: *SqliteMemorySystem, session_id: []const u8, role: []const u8, content: []const u8) SqlError!void {
        const sql = "INSERT INTO messages (session_id, role, content, timestamp) VALUES (?, ?, ?, ?)";
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const timestamp = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds();

        // Use -1 to avoid use-after-free
        const session_id_heap = try self.heapAllocString(session_id);
        defer self.allocator.free(session_id_heap);
        const role_heap = try self.heapAllocString(role);
        defer self.allocator.free(role_heap);
        const content_heap = try self.heapAllocString(content);
        defer self.allocator.free(content_heap);

        _ = c.sqlite3_bind_text(stmt, 1, session_id_heap.ptr, -1, SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 2, role_heap.ptr, -1, SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_text(stmt, 3, content_heap.ptr, -1, SQLITE_TRANSIENT);
        _ = c.sqlite3_bind_int64(stmt, 4, timestamp);

        const step_rc = c.sqlite3_step(stmt);
        if (step_rc != c.SQLITE_DONE) return SqlError.StepFailed;

        const update_sql = "UPDATE sessions SET updated_at = ? WHERE id = ?";
        var update_stmt: ?*c.sqlite3_stmt = null;
        const update_rc = c.sqlite3_prepare_v2(self.db, update_sql, -1, &update_stmt, null);
        if (update_rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(update_stmt);
            _ = c.sqlite3_bind_int64(update_stmt, 1, timestamp);
            _ = c.sqlite3_bind_text(update_stmt, 2, session_id_heap.ptr, -1, SQLITE_TRANSIENT);
            _ = c.sqlite3_step(update_stmt);
        }
    }

    pub fn getHistoryJSON(self: *SqliteMemorySystem, allocator: std.mem.Allocator, session_id: []const u8) SqlError![]u8 {
        const sql = "SELECT role, content, timestamp FROM messages WHERE session_id = ? ORDER BY timestamp ASC";
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        // Use -1 to avoid use-after-free
        const session_id_heap = try self.heapAllocString(session_id);
        defer self.allocator.free(session_id_heap);

        _ = c.sqlite3_bind_text(stmt, 1, session_id_heap.ptr, -1, SQLITE_TRANSIENT);

        var messages = std.ArrayList(u8).empty;
        defer messages.deinit(allocator);

        try messages.appendSlice(allocator, "[");
        var first = true;
        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            if (!first) try messages.appendSlice(allocator, ",");
            first = false;
            const role = c.sqlite3_column_text(stmt, 0);
            const content = c.sqlite3_column_text(stmt, 1);
            const timestamp = c.sqlite3_column_int64(stmt, 2);
            if (role != null and content != null) {
                const role_len = @as(usize, @intCast(c.sqlite3_column_bytes(stmt, 0)));
                const content_len = @as(usize, @intCast(c.sqlite3_column_bytes(stmt, 1)));
                try messages.appendSlice(allocator, "{\"role\":\"");
                try messages.appendSlice(allocator, role[0..role_len]);
                try messages.appendSlice(allocator, "\",\"content\":\"");
                try messages.appendSlice(allocator, content[0..content_len]);
                try messages.appendSlice(allocator, "\",\"timestamp\":");
                const ts_str = try std.fmt.allocPrint(allocator, "{d}", .{timestamp});
                defer allocator.free(ts_str);
                try messages.appendSlice(allocator, ts_str);
                try messages.appendSlice(allocator, "}");
            }
        }
        return try messages.toOwnedSlice(allocator);
    }

    pub fn getSession(self: *SqliteMemorySystem, session_id: []const u8) SqlError!?struct { created_at: i64, updated_at: i64 } {
        const sql = "SELECT created_at, updated_at FROM sessions WHERE id = ?";
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const session_id_heap = try self.heapAllocString(session_id);
        defer self.allocator.free(session_id_heap);

        _ = c.sqlite3_bind_text(stmt, 1, session_id_heap.ptr, -1, SQLITE_TRANSIENT);

        if (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const created_at = c.sqlite3_column_int64(stmt, 0);
            const updated_at = c.sqlite3_column_int64(stmt, 1);
            return .{ .created_at = created_at, .updated_at = updated_at };
        }

        return null;
    }

    pub fn deleteSession(self: *SqliteMemorySystem, session_id: []const u8) SqlError!void {
        const sql = "DELETE FROM messages WHERE session_id = ?";
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        const session_id_heap = try self.heapAllocString(session_id);
        defer self.allocator.free(session_id_heap);

        _ = c.sqlite3_bind_text(stmt, 1, session_id_heap.ptr, -1, SQLITE_TRANSIENT);
        _ = c.sqlite3_step(stmt);

        const delete_session_sql = "DELETE FROM sessions WHERE id = ?";
        var delete_stmt: ?*c.sqlite3_stmt = null;
        const delete_rc = c.sqlite3_prepare_v2(self.db, delete_session_sql, -1, &delete_stmt, null);
        if (delete_rc == c.SQLITE_OK) {
            defer _ = c.sqlite3_finalize(delete_stmt);
            _ = c.sqlite3_bind_text(delete_stmt, 1, session_id_heap.ptr, -1, SQLITE_TRANSIENT);
            _ = c.sqlite3_step(delete_stmt);
        }
    }

    pub fn listSessions(self: *SqliteMemorySystem, allocator: std.mem.Allocator) SqlError![][]const u8 {
        const sql = "SELECT id FROM sessions ORDER BY updated_at DESC";
        var stmt: ?*c.sqlite3_stmt = null;

        const rc = c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null);
        if (rc != c.SQLITE_OK) return SqlError.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        var sessions = std.ArrayList([]const u8).empty;
        errdefer {
            for (sessions.items) |s| allocator.free(s);
            sessions.deinit(allocator);
        }

        while (c.sqlite3_step(stmt) == c.SQLITE_ROW) {
            const id = c.sqlite3_column_text(stmt, 0);
            if (id != null) {
                const id_len = @as(usize, @intCast(c.sqlite3_column_bytes(stmt, 0)));
                const id_copy = try allocator.dupe(u8, id[0..id_len]);
                try sessions.append(allocator, id_copy);
            }
        }

        return try sessions.toOwnedSlice(allocator);
    }
};
