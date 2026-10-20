//! Stub tools must not report success or appear in the default registry.

const std = @import("std");
const factory = @import("factory.zig");
const root = @import("root.zig");
const homeassistant_tool = @import("homeassistant_tool.zig");
const image_generation = @import("image_generation.zig");
const send_message_tool = @import("send_message_tool.zig");
const tts_tool = @import("tts_tool.zig");

fn expectUnavailable(result: root.ToolResult) !void {
    try std.testing.expect(result.success == false);
    try std.testing.expect(result.error_msg != null);
    try std.testing.expect(result.error_msg.?.len > 0);
}

test "stub tools report failure instead of success" {
    const allocator = std.testing.allocator;

    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"action\":\"get_state\"}", .{});
        defer parsed.deinit();
        var tool = homeassistant_tool.HomeAssistantTool{};
        const result = try tool.execute(allocator, parsed.value.object);
        try expectUnavailable(result);
    }
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"prompt\":\"a red cube\"}", .{});
        defer parsed.deinit();
        var tool = image_generation.ImageGenerationTool{};
        const result = try tool.execute(allocator, parsed.value.object);
        try expectUnavailable(result);
    }
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"platform\":\"slack\",\"recipient\":\"#dev\",\"message\":\"hi\"}", .{});
        defer parsed.deinit();
        var tool = send_message_tool.SendMessageTool{};
        const result = try tool.execute(allocator, parsed.value.object);
        try expectUnavailable(result);
    }
    {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{\"text\":\"hello\"}", .{});
        defer parsed.deinit();
        var tool = tts_tool.TtsTool{};
        const result = try tool.execute(allocator, parsed.value.object);
        try expectUnavailable(result);
    }
}

test "default registry does not advertise stub tools" {
    const allocator = std.testing.allocator;
    var registry = try factory.createDefaultRegistry(allocator, ".");
    defer registry.deinit();

    const banned = [_][]const u8{ "homeassistant", "image_generation", "send_message", "tts" };
    for (registry.list()) |entry| {
        for (banned) |name| {
            try std.testing.expect(!std.mem.eql(u8, entry.spec.name, name));
        }
    }
}
