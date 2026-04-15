//! Credential Pool - Rotate through multiple API keys
const std = @import("std");

pub const CredentialPool = struct {
    allocator: std.mem.Allocator,
    keys: [][]const u8,
    current: std.atomic.Value(usize),

    pub fn init(allocator: std.mem.Allocator, keys: [][]const u8) CredentialPool {
        return .{
            .allocator = allocator,
            .keys = keys,
            .current = std.atomic.Value(usize).init(0),
        };
    }

    pub fn deinit(self: *CredentialPool) void {
        for (self.keys) |k| self.allocator.free(k);
        self.allocator.free(self.keys);
    }

    pub fn nextKey(self: *CredentialPool) []const u8 {
        if (self.keys.len == 0) return "";
        const idx = self.current.fetchAdd(1, .monotonic) % self.keys.len;
        return self.keys[idx];
    }
};
