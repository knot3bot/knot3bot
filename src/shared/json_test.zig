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

test "jsonSuccess - creates success response" {
    const allocator = std.testing.allocator;
    const result = try json.jsonSuccess(allocator, "Operation completed");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "status") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Operation completed") != null);
}

test "getJsonString - extracts string from object" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"test\",\"age\":42}", .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;

    const name = json.getJsonString(obj, "name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("test", name.?);

    const age = json.getJsonString(obj, "age");
    try std.testing.expect(age == null); // age is number, not string
}

test "getJsonString - returns null for missing keys" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"test\"}", .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const result = json.getJsonString(obj, "nonexistent");
    try std.testing.expect(result == null);
}

test "getJsonBool - extracts boolean from object" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"enabled\":true,\"count\":42}", .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;

    const enabled = json.getJsonBool(obj, "enabled");
    try std.testing.expect(enabled != null);
    try std.testing.expect(enabled.? == true);

    const count = json.getJsonBool(obj, "count");
    try std.testing.expect(count == null); // count is number, not bool
}

test "getJsonInt - extracts integer from object" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"count\":42,\"name\":\"test\"}", .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;

    const count = json.getJsonInt(obj, "count");
    try std.testing.expect(count != null);
    try std.testing.expect(count.? == 42);

    const name = json.getJsonInt(obj, "name");
    try std.testing.expect(name == null); // name is string, not int
}

test "getJsonFloat - extracts float from object" {
    const allocator = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"price\":19.99,\"count\":42}", .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;

    const price = json.getJsonFloat(obj, "price");
    try std.testing.expect(price != null);
    try std.testing.expect(price.? == 19.99);

    // Integers should also be convertible to float
    const count = json.getJsonFloat(obj, "count");
    try std.testing.expect(count != null);
    try std.testing.expect(count.? == 42.0);
}

test "getJsonObject - extracts object from value" {
    const allocator = std.testing.allocator;
    // Parse a simple object
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"name\":\"test\"}", .{});
    defer parsed.deinit();

    const obj_opt = json.getJsonObject(parsed.value);
    try std.testing.expect(obj_opt != null);

    // Now we can use getJsonString on this object
    const name = json.getJsonString(&obj_opt.?, "name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("test", name.?);
}
