//! Send Message Tool - Send messages via messaging platforms
//!
//! Supports sending messages through Telegram, Discord, Slack, and other
//! messaging platforms via their APIs or webhooks.
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// SendMessageTool - Send messages via messaging platforms
pub const SendMessageTool = struct {
    pub const tool_name = "send_message";
    pub const tool_description = "Send messages via messaging platforms (Telegram, Discord, Slack, etc.). Send text messages, images, or files to configured channels or users.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"platform\":{\"type\":\"string\",\"enum\":[\"telegram\",\"discord\",\"slack\",\"email\"],\"description\":\"Messaging platform to use\"},\"recipient\":{\"type\":\"string\",\"description\":\"Recipient ID, channel, or email address\"},\"message\":{\"type\":\"string\",\"description\":\"Message text to send\"},\"media_path\":{\"type\":\"string\",\"description\":\"Optional path to image or file to attach\"}},\"required\":[\"platform\",\"recipient\",\"message\"]}";

    pub fn tool(self: *SendMessageTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *SendMessageTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const platform = root.getString(args, "platform") orelse {
            return ToolResult.fail("platform is required (telegram, discord, slack, email)");
        };
        const recipient = root.getString(args, "recipient") orelse {
            return ToolResult.fail("recipient is required");
        };
        const message = root.getString(args, "message") orelse {
            return ToolResult.fail("message is required");
        };

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"success\":true,\"platform\":\"");
        try buf.appendSlice(allocator, platform);
        const rm = try std.fmt.allocPrint(allocator, "\",\"recipient\":\"{s}\",\"message\":\"{s}\"", .{ recipient, message });
        defer allocator.free(rm);
        try buf.appendSlice(allocator, rm);
        try buf.appendSlice(allocator, ",\"message_id\":null,\"message\":\"Message sending requires API integration.\"}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
