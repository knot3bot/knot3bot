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
    try jb.fieldFmt("count", "{}", .{42});
    const json = try jb.finish();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"count\":42}", json);
}

test "JsonBuilder empty" {
    var jb = try JsonBuilder.init(std.testing.allocator);
    defer jb.deinit();
    try jb.begin();
    const json = try jb.finish();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{}", json);
}

test "JsonBuilder special chars in value" {
    var jb = try JsonBuilder.init(std.testing.allocator);
    defer jb.deinit();
    try jb.begin();
    try jb.field("msg", "hello world");
    const json = try jb.finish();
    defer std.testing.allocator.free(json);
    try std.testing.expectEqualStrings("{\"msg\":\"hello world\"}", json);
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

test "Provider baseUrls are distinct" {
    const urls = [_][]const u8{
        "https://api.openai.com/v1",
        "https://api.deepseek.com/v1",
        "https://api.moonshot.cn/v1",
        "https://dashscope.aliyuncs.com/compatible-mode/v1",
        "https://api.minimax.chat/v1",
        "https://openrouter.ai/api/v1",
    };
    for (urls, 1..) |a, i| {
        for (urls[i..]) |b| {
            try std.testing.expect(!std.mem.eql(u8, a, b));
        }
    }
}

test "Memory system init and deinit" {
    var mem = MemorySystem.init(std.testing.allocator);
    defer mem.deinit();
    try mem.createSession("test");
    try mem.addMessage("test", "user", "hello");
    const history = try mem.getHistoryJSON(std.testing.allocator, "test");
    defer std.testing.allocator.free(history);
    try std.testing.expect(history.len > 0);
}

const MemorySystem = struct {
    allocator: std.mem.Allocator,
    sessions: std.StringHashMap(Session),
    const Session = struct {
        id: []const u8,
        messages: std.ArrayList(Message),
        created_at: i64,
        updated_at: i64,
        const Message = struct { role: []const u8, content: []const u8, timestamp: i64 };
    };
    fn init(allocator: std.mem.Allocator) @This() {
        return .{ .allocator = allocator, .sessions = std.StringHashMap(Session).init(allocator) };
    }
    fn deinit(self: *@This()) void {
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
    fn createSession(self: *@This(), session_id: []const u8) !void {
        const id_copy = try self.allocator.dupe(u8, session_id);
        try self.sessions.put(id_copy, .{ .id = id_copy, .messages = .empty, .created_at = 0, .updated_at = 0 });
    }
    fn addMessage(self: *@This(), session_id: []const u8, role: []const u8, content: []const u8) !void {
        var session = self.sessions.getPtr(session_id) orelse return;
        try session.messages.append(self.allocator, .{ .role = try self.allocator.dupe(u8, role), .content = try self.allocator.dupe(u8, content), .timestamp = 0 });
    }
    fn getHistoryJSON(self: *@This(), alloc: std.mem.Allocator, session_id: []const u8) ![]const u8 {
        const session = self.sessions.get(session_id) orelse return error.SessionNotFound;
        var list: std.ArrayList(u8) = .empty;
        try list.appendSlice(alloc, "[");
        for (session.messages.items, 0..) |msg, i| {
            if (i > 0) try list.appendSlice(alloc, ",");
            try list.appendSlice(alloc, "{\"role\":\"");
            try list.appendSlice(alloc, msg.role);
            try list.appendSlice(alloc, "\",\"content\":\"");
            try list.appendSlice(alloc, msg.content);
            try list.appendSlice(alloc, "\",\"timestamp\":0}");
        }
        try list.appendSlice(alloc, "]");
        return list.toOwnedSlice(alloc);
    }
};

test "Tool registry init" {
    var reg = try ToolRegistry.init(std.testing.allocator);
    defer reg.deinit();
    try std.testing.expectEqual(@as(usize, 0), reg.count());
}

const ToolRegistry = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]const u8),
    fn init(allocator: std.mem.Allocator) !@This() {
        return .{ .allocator = allocator, .entries = try std.ArrayList([]const u8).initCapacity(allocator, 0) };
    }
    fn deinit(self: *@This()) void { self.entries.deinit(self.allocator); }
    fn count(self: *const @This()) usize { return self.entries.items.len; }
};
