//! Shared JSON utilities — escape, build, parse.

const std = @import("std");

/// Escapes a string for safe inclusion in JSON values.
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    for (input) |char| {
        switch (char) {
            '"' => try result.appendSlice(allocator, "\\\""),
            '\\' => try result.appendSlice(allocator, "\\\\"),
            '\n' => try result.appendSlice(allocator, "\\n"),
            '\r' => try result.appendSlice(allocator, "\\r"),
            '\t' => try result.appendSlice(allocator, "\\t"),
            else => try result.append(allocator, char),
        }
    }
    return result.toOwnedSlice(allocator);
}

/// Simple chainable JSON builder — eliminates the appendSlice+allocPrint pattern.
pub const JsonBuilder = struct {
    allocator: std.mem.Allocator,
    buf: std.ArrayList(u8),
    need_comma: bool = false,

    pub fn init(allocator: std.mem.Allocator) !JsonBuilder {
        return .{ .allocator = allocator, .buf = try std.ArrayList(u8).initCapacity(allocator, 256) };
    }

    pub fn deinit(self: *JsonBuilder) void { self.buf.deinit(self.allocator); }

    pub fn begin(self: *JsonBuilder) !void {
        try self.buf.appendSlice(self.allocator, "{");
        self.need_comma = false;
    }

    pub fn field(self: *JsonBuilder, key: []const u8, value: []const u8) !void {
        try self.comma();
        try self.buf.appendSlice(self.allocator, "\"");
        try self.buf.appendSlice(self.allocator, key);
        try self.buf.appendSlice(self.allocator, "\":\"");
        try self.buf.appendSlice(self.allocator, value);
        try self.buf.appendSlice(self.allocator, "\"");
    }

    pub fn fieldRaw(self: *JsonBuilder, key: []const u8, value: []const u8) !void {
        try self.comma();
        try self.buf.appendSlice(self.allocator, "\"");
        try self.buf.appendSlice(self.allocator, key);
        try self.buf.appendSlice(self.allocator, "\":");
        try self.buf.appendSlice(self.allocator, value);
    }

    pub fn fieldFmt(self: *JsonBuilder, key: []const u8, comptime fmt: []const u8, args: anytype) !void {
        try self.comma();
        try self.buf.appendSlice(self.allocator, "\"");
        try self.buf.appendSlice(self.allocator, key);
        try self.buf.appendSlice(self.allocator, "\":");
        const val = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(val);
        try self.buf.appendSlice(self.allocator, val);
    }

    fn comma(self: *JsonBuilder) !void {
        if (self.need_comma) try self.buf.appendSlice(self.allocator, ",");
        self.need_comma = true;
    }

    pub fn finish(self: *JsonBuilder) ![]const u8 {
        try self.buf.appendSlice(self.allocator, "}");
        return self.buf.toOwnedSlice(self.allocator);
    }
};

/// Simple JSON success response.
pub fn jsonOk(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"success\":true,\"message\":\"{s}\"}}", .{message});
}

pub fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{{\"error\":{{\"message\":\"{s}\"}}}}", .{message});
}
