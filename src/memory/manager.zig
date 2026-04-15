//! Memory Manager - Multi-provider memory orchestration
//!
//! Coordinates multiple memory backends (in-memory, SQLite, etc.)
//! Writes propagate to all backends; reads use the first successful backend.

const std = @import("std");
const MemorySystem = @import("../memory.zig").MemorySystem;
const SqliteMemorySystem = @import("sqlite.zig").SqliteMemorySystem;

pub const MemoryBackend = union(enum) {
    memory: *MemorySystem,
    sqlite: *SqliteMemorySystem,
};

pub const MemoryManager = struct {
    allocator: std.mem.Allocator,
    backends: []MemoryBackend,

    pub fn init(allocator: std.mem.Allocator, backends: []MemoryBackend) MemoryManager {
        return .{
            .allocator = allocator,
            .backends = backends,
        };
    }

    pub fn deinit(self: *MemoryManager) void {
        self.allocator.free(self.backends);
    }

    pub fn createSession(self: *MemoryManager, session_id: []const u8) !void {
        var first_err: ?anyerror = null;
        for (self.backends) |backend| {
            const result = switch (backend) {
                .memory => |b| b.createSession(session_id),
                .sqlite => |b| b.createSession(session_id),
            };
            if (result) |_| {} else |err| {
                if (first_err == null) first_err = err;
                std.log.warn("MemoryManager: createSession failed for backend: {s}", .{@errorName(err)});
            }
        }
        if (first_err) |err| return err;
    }

    pub fn addMessage(self: *MemoryManager, session_id: []const u8, role: []const u8, content: []const u8) !void {
        var first_err: ?anyerror = null;
        for (self.backends) |backend| {
            const result = switch (backend) {
                .memory => |b| b.addMessage(session_id, role, content),
                .sqlite => |b| b.addMessage(session_id, role, content),
            };
            if (result) |_| {} else |err| {
                if (first_err == null) first_err = err;
                std.log.warn("MemoryManager: addMessage failed for backend: {s}", .{@errorName(err)});
            }
        }
        if (first_err) |err| return err;
    }

    pub fn getHistoryJSON(self: *MemoryManager, allocator: std.mem.Allocator, session_id: []const u8) !?[]const u8 {
        for (self.backends) |backend| {
            const result = switch (backend) {
                .memory => |b| b.getHistoryJSON(allocator, session_id),
                .sqlite => |b| b.getHistoryJSON(allocator, session_id),
            };
            if (result) |history| {
                if (history) |h| return h;
            } else |err| {
                std.log.warn("MemoryManager: getHistoryJSON failed for backend: {s}", .{@errorName(err)});
            }
        }
        return null;
    }

    pub fn deleteSession(self: *MemoryManager, session_id: []const u8) void {
        for (self.backends) |backend| {
            switch (backend) {
                .memory => |b| b.deleteSession(session_id),
                .sqlite => |b| b.deleteSession(session_id) catch {},
            }
        }
    }

    pub fn listSessions(self: *MemoryManager, allocator: std.mem.Allocator) ![]const []const u8 {
        for (self.backends) |backend| {
            const result = switch (backend) {
                .memory => |b| b.listSessions(allocator),
                .sqlite => |b| b.listSessions(allocator),
            };
            if (result) |sessions| {
                return sessions;
            } else |err| {
                std.log.warn("MemoryManager: listSessions failed for backend: {s}", .{@errorName(err)});
            }
        }
        return &.{};
    }
};
