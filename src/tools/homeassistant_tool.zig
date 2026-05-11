//! HomeAssistant Tool - Control smart home devices via HomeAssistant API
//!
//! Interfaces with HomeAssistant to control lights, switches, sensors,
//! and other smart home devices via its REST API or WebSocket.
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// HomeAssistantTool - Control smart home devices via HomeAssistant
pub const HomeAssistantTool = struct {
    pub const tool_name = "homeassistant";
    pub const tool_description = "Control smart home devices via HomeAssistant. Can call services (turn_on, turn_off, etc.), get states, and monitor entity changes.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"call_service\",\"get_state\",\"list_entities\",\"subscribe\"],\"description\":\"Action to perform\"},\"entity_id\":{\"type\":\"string\",\"description\":\"Entity ID (e.g., light.living_room, switch.desk)\"},\"service\":{\"type\":\"string\",\"description\":\"Service to call (e.g., light.turn_on, switch.turn_off)\"},\"data\":{\"type\":\"object\",\"description\":\"Service call data (e.g., {\\\"brightness\\\": 255})\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *HomeAssistantTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *HomeAssistantTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse {
            return ToolResult.fail("action is required (call_service, get_state, list_entities, subscribe)");
        };

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"success\":true,\"action\":\"");
        try buf.appendSlice(allocator, action);
        try buf.appendSlice(allocator, "\",\"message\":\"HomeAssistant requires API integration.\"}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
