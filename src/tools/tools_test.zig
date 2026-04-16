//! Tool registry and utilities tests
const std = @import("std");
const root = @import("root.zig");
const ToolResult = root.ToolResult;
const ToolSpec = root.ToolSpec;
const Tool = root.Tool;
const ToolRegistry = root.ToolRegistry;

// ============================================================================
// ToolResult Tests
// ============================================================================

test "ToolResult.ok - creates successful result" {
    const result = ToolResult.ok("Operation succeeded");
    try std.testing.expect(result.success);
    try std.testing.expectEqualStrings("Operation succeeded", result.output);
    try std.testing.expect(result.error_msg == null);
}

test "ToolResult.fail - creates failed result" {
    const result = ToolResult.fail("Something went wrong");
    try std.testing.expect(!result.success);
    try std.testing.expectEqualStrings("", result.output);
    try std.testing.expectEqualStrings("Something went wrong", result.error_msg.?);
}

// ============================================================================
// ToolSpec Tests
// ============================================================================

test "ToolSpec - creates valid spec" {
    const spec = ToolSpec{
        .name = "test_tool",
        .description = "A test tool for unit testing",
        .parameters_json = "{\"type\":\"object\",\"properties\":{}}",
    };
    try std.testing.expectEqualStrings("test_tool", spec.name);
    try std.testing.expectEqualStrings("A test tool for unit testing", spec.description);
    try std.testing.expectEqualStrings("{\"type\":\"object\",\"properties\":{}}", spec.parameters_json);
}

// ============================================================================
// JSON Extraction Helpers Tests
// ============================================================================

test "getString - extracts string value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str =
        \\{"name":"test","value":42,"enabled":true}
    ;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const name = root.getString(obj, "name");
    try std.testing.expect(name != null);
    try std.testing.expectEqualStrings("test", name.?);
}

test "getString - returns null for non-string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"count\":42}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const count = root.getString(obj, "count");
    try std.testing.expect(count == null);
}

test "getString - returns null for missing keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"name\":\"test\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const missing = root.getString(obj, "nonexistent");
    try std.testing.expect(missing == null);
}

test "getBool - extracts boolean value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"enabled\":true,\"disabled\":false,\"count\":42}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const enabled = root.getBool(obj, "enabled");
    try std.testing.expect(enabled != null);
    try std.testing.expect(enabled.? == true);

    const disabled = root.getBool(obj, "disabled");
    try std.testing.expect(disabled != null);
    try std.testing.expect(disabled.? == false);
}

test "getBool - returns null for non-boolean values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"count\":42}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const count = root.getBool(obj, "count");
    try std.testing.expect(count == null);
}

test "getInt - extracts integer value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"count\":42,\"name\":\"test\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const count = root.getInt(obj, "count");
    try std.testing.expect(count != null);
    try std.testing.expect(count.? == 42);
}

test "getInt - returns null for non-integer values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"name\":\"test\",\"price\":19.99}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const name = root.getInt(obj, "name");
    try std.testing.expect(name == null);

    const price = root.getInt(obj, "price");
    try std.testing.expect(price == null);
}

test "getValue - extracts raw JSON value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"nested\":{\"key\":\"value\"},\"simple\":\"text\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const nested = root.getValue(obj, "nested");
    try std.testing.expect(nested != null);
    try std.testing.expect(nested.? == .object);

    const simple = root.getValue(obj, "simple");
    try std.testing.expect(simple != null);
    try std.testing.expect(simple.? == .string);
}

test "getValue - returns null for missing keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"name\":\"test\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const missing = root.getValue(obj, "nonexistent");
    try std.testing.expect(missing == null);
}

test "getStringArray - extracts array of strings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"names\":[\"alice\",\"bob\",\"charlie\"]}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const names = root.getStringArray(obj, "names");
    try std.testing.expect(names != null);
    try std.testing.expectEqual(@as(usize, 3), names.?.len);
}

test "getStringArray - returns null for non-array values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"count\":42}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj = &parsed.value.object;
    const count = root.getStringArray(obj, "count");
    try std.testing.expect(count == null);
}

// ============================================================================
// ToolRegistry Tests (Basic)
// ============================================================================

test "ToolRegistry.init - creates empty registry" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "ToolRegistry.list - returns empty slice for new registry" {
    const allocator = std.testing.allocator;
    var registry = ToolRegistry.init(allocator);
    defer registry.deinit();

    const tools = registry.list();
    try std.testing.expectEqual(@as(usize, 0), tools.len);
}

// ============================================================================
// JsonValue and JsonObjectMap type aliases
// ============================================================================

test "JsonValue type alias works correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"name\":\"test\",\"count\":42}";
    const parsed = try std.json.parseFromSlice(root.JsonValue, allocator, json_str, .{});
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .object);
    try std.testing.expectEqual(@as(usize, 2), parsed.value.object.count());
}

test "JsonObjectMap type alias works correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = "{\"key\":\"value\"}";
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
    defer parsed.deinit();

    const obj: root.JsonObjectMap = parsed.value.object;
    try std.testing.expectEqual(@as(usize, 1), obj.count());
}
