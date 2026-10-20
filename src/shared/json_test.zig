const std = @import("std");
const json = @import("json.zig");

test "escapeJsonString - escapes special characters" {
    const allocator = std.testing.allocator;

    // Test basic escaping
    const result1 = try json.escapeJsonString(allocator, "hello");
    defer allocator.free(result1);
    try std.testing.expectEqualStrings("hello", result1);

    // Test double quote escaping
    const result2 = try json.escapeJsonString(allocator, "say \"hello\"");
    defer allocator.free(result2);
    try std.testing.expectEqualStrings("say \\\"hello\\\"", result2);

    // Test backslash escaping
    const result3 = try json.escapeJsonString(allocator, "path\\to\\file");
    defer allocator.free(result3);
    try std.testing.expectEqualStrings("path\\\\to\\\\file", result3);

    // Test newline escaping
    const result4 = try json.escapeJsonString(allocator, "line1\nline2");
    defer allocator.free(result4);
    try std.testing.expectEqualStrings("line1\\nline2", result4);

    // Test carriage return escaping
    const result5 = try json.escapeJsonString(allocator, "line1\rline2");
    defer allocator.free(result5);
    try std.testing.expectEqualStrings("line1\\rline2", result5);

    // Test tab escaping
    const result6 = try json.escapeJsonString(allocator, "col1\tcol2");
    defer allocator.free(result6);
    try std.testing.expectEqualStrings("col1\\tcol2", result6);
}

test "escapeJsonString - handles empty string" {
    const allocator = std.testing.allocator;
    const result = try json.escapeJsonString(allocator, "");
    defer allocator.free(result);
    try std.testing.expectEqualStrings("", result);
}

test "jsonError - creates error response" {
    const allocator = std.testing.allocator;
    const result = try json.jsonError(allocator, "Something went wrong");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Something went wrong") != null);
}

test "jsonError - escapes special characters in error message" {
    const allocator = std.testing.allocator;
    const result = try json.jsonError(allocator, "Error with \"quotes\" and \\backslash\\");
    defer allocator.free(result);
    // Should contain escaped versions
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"quotes\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\\backslash\\\\") != null);
}
