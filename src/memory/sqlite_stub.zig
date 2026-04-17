const std = @import("std");

pub const SqlError = error{NotCompiled};

pub const SqliteMemorySystem = struct {
    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) SqlError!SqliteMemorySystem {
        _ = allocator;
        _ = db_path;
        return error.NotCompiled;
    }

    pub fn deinit(self: *SqliteMemorySystem) void {
        _ = self;
    }

    pub fn createSession(self: *SqliteMemorySystem, session_id: []const u8) SqlError!void {
        _ = self;
        _ = session_id;
        return error.NotCompiled;
    }

    pub fn addMessage(self: *SqliteMemorySystem, session_id: []const u8, role: []const u8, content: []const u8) SqlError!void {
        _ = self;
        _ = session_id;
        _ = role;
        _ = content;
        return error.NotCompiled;
    }

    pub fn getHistoryJSON(self: *SqliteMemorySystem, allocator: std.mem.Allocator, session_id: []const u8) SqlError![]u8 {
        _ = self;
        _ = allocator;
        _ = session_id;
        return error.NotCompiled;
    }

    pub fn getSession(self: *SqliteMemorySystem, session_id: []const u8) SqlError!?struct { created_at: i64, updated_at: i64 } {
        _ = self;
        _ = session_id;
        return error.NotCompiled;
    }

    pub fn deleteSession(self: *SqliteMemorySystem, session_id: []const u8) SqlError!void {
        _ = self;
        _ = session_id;
        return error.NotCompiled;
    }

    pub fn listSessions(self: *SqliteMemorySystem, allocator: std.mem.Allocator) SqlError![][]const u8 {
        _ = self;
        _ = allocator;
        return error.NotCompiled;
    }
};
