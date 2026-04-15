//! JSON utilities for working with OpenAI-compatible API schemas

const std = @import("std");

/// Escapes a string for safe inclusion in JSON
pub fn escapeJsonString(allocator: std.mem.Allocator, input: []const u8) ![]const u8 {
    var result = try std.array_list.AlignedManaged(u8, null).initCapacity(allocator, 0);

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

    return try result.toOwnedSlice(allocator);
}

/// Builds a JSON error response
pub fn jsonError(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const escaped = try escapeJsonString(allocator, message);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator, "{{\"error\":{{\"message\":\"{s}\"}}}}", .{escaped});
}

/// Builds a JSON success response with a message
pub fn jsonSuccess(allocator: std.mem.Allocator, message: []const u8) ![]const u8 {
    const escaped = try escapeJsonString(allocator, message);
    defer allocator.free(escaped);

    return std.fmt.allocPrint(allocator, "{{\"status\":\"ok\",\"message\":\"{s}\"}}", .{escaped});
}

/// Extracts a string value from a JSON object, returning null if not found or not a string
pub fn getJsonString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .string => |s| s,
        else => null,
    };
}

/// Extracts an optional string value from a JSON object
pub fn getOptionalString(obj: *const std.json.ObjectMap, key: []const u8) ?[]const u8 {
    return getJsonString(obj, key);
}

/// Extracts a boolean value from a JSON object, returning null if not found or not a bool
pub fn getJsonBool(obj: *const std.json.ObjectMap, key: []const u8) ?bool {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .bool => |b| b,
        else => null,
    };
}

/// Extracts an integer value from a JSON object, returning null if not found or not an integer
pub fn getJsonInt(obj: *const std.json.ObjectMap, key: []const u8) ?i64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .integer => |i| i,
        else => null,
    };
}

/// Extracts a float value from a JSON object, returning null if not found or not a number
pub fn getJsonFloat(obj: *const std.json.ObjectMap, key: []const u8) ?f64 {
    const val = obj.get(key) orelse return null;
    return switch (val) {
        .float => |f| f,
        .integer => |i| @as(f64, @floatFromInt(i)),
        else => null,
    };
}

/// Parses a JSON value and returns an ObjectMap if it's an object, otherwise null
pub fn getJsonObject(val: std.json.Value) ?std.json.ObjectMap {
    return switch (val) {
        .object => |obj| obj,
        else => null,
    };
}
