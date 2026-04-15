//! Prompt Cache - Simple response caching for identical prompts
const std = @import("std");

pub const PromptCache = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),

    pub fn init(allocator: std.mem.Allocator) PromptCache {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *PromptCache) void {
        var it = self.map.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            self.allocator.free(entry.value_ptr.*);
        }
        self.map.deinit();
    }

    pub fn get(self: *PromptCache, prompt: []const u8) ?[]const u8 {
        return self.map.get(prompt);
    }

    pub fn put(self: *PromptCache, prompt: []const u8, response: []const u8) !void {
        const key = try self.allocator.dupe(u8, prompt);
        errdefer self.allocator.free(key);
        const val = try self.allocator.dupe(u8, response);
        try self.map.put(key, val);
    }
};
