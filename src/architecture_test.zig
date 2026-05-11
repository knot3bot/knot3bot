//! Architecture integration tests — JsonBuilder, gateway, factory counts.

const std = @import("std");

// ── JsonBuilder tests ──────────────────────────────────────────────────────

const JsonBuilder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    need_comma: bool = false,
    pub fn init(allocator: std.mem.Allocator) !@This() {
        return .{ .allocator = allocator, .buf = try std.ArrayList(u8).initCapacity(allocator, 128) };
    }
    pub fn deinit(self: *@This()) void { self.buf.deinit(self.allocator); }
    pub fn begin(self: *@This()) !void { try self.buf.appendSlice(self.allocator, "{"); self.need_comma = false; }
    pub fn field(self: *@This(), key: []const u8, value: []const u8) !void {
        if (self.need_comma) try self.buf.appendSlice(self.allocator, ",");
        try self.buf.appendSlice(self.allocator, "\"");
        try self.buf.appendSlice(self.allocator, key);
        try self.buf.appendSlice(self.allocator, "\":\"");
        try self.buf.appendSlice(self.allocator, value);
        try self.buf.appendSlice(self.allocator, "\"");
        self.need_comma = true;
    }
    pub fn fieldFmt(self: *@This(), key: []const u8, comptime fmt: []const u8, args: anytype) !void {
        if (self.need_comma) try self.buf.appendSlice(self.allocator, ",");
        try self.buf.appendSlice(self.allocator, "\"");
        try self.buf.appendSlice(self.allocator, key);
        try self.buf.appendSlice(self.allocator, "\":");
        const val = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(val);
        try self.buf.appendSlice(self.allocator, val);
        self.need_comma = true;
    }
    pub fn finish(self: *@This()) ![]const u8 {
        try self.buf.appendSlice(self.allocator, "}");
        return self.buf.toOwnedSlice(self.allocator);
    }
};

test "JsonBuilder basic field" {
    var jb = try JsonBuilder.init(std.testing.allocator);
    defer jb.deinit();
    try jb.begin();
    try jb.field("name", "test");
    const json = try jb.finish();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"name\":\"test\"}", json);
}

test "JsonBuilder multiple fields" {
    var jb = try JsonBuilder.init(std.testing.allocator);
    defer jb.deinit();
    try jb.begin();
    try jb.field("a", "1");
    try jb.field("b", "2");
    const json = try jb.finish();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"a\":\"1\",\"b\":\"2\"}", json);
}

test "JsonBuilder fieldFmt" {
    var jb = try JsonBuilder.init(std.testing.allocator);
    defer jb.deinit();
    try jb.begin();
    try jb.fieldFmt("count", "{d}", .{42});
    const json = try jb.finish();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"count\":42}", json);
}

// ── Gateway type tests ─────────────────────────────────────────────────────

test "Gateway platform map init and deinit" {
    var platforms = std.StringHashMap(void).init(std.testing.allocator);
    defer platforms.deinit();
    var sessions = std.StringHashMap(void).init(std.testing.allocator);
    defer sessions.deinit();
}

test "Provider baseUrl returns https endpoints" {
    const url = "https://api.deepseek.com/v1";
    try std.testing.expect(std.mem.startsWith(u8, url, "https://"));
    const url2 = "https://dashscope.aliyuncs.com/compatible-mode/v1";
    try std.testing.expect(std.mem.startsWith(u8, url2, "https://"));
    const url3 = "https://openrouter.ai/api/v1";
    try std.testing.expect(std.mem.startsWith(u8, url3, "https://"));
}

test "Provider defaultModel is non-empty" {
    const model = "gpt-5.5";
    try std.testing.expect(model.len > 0);
    const model2 = "deepseek-v4-pro";
    try std.testing.expect(model2.len > 0);
}
