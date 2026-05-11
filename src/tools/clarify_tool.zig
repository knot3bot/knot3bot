//! Clarify Tool - Interactive Clarifying Questions
//!
//! Allows the agent to present structured multiple-choice questions or open-ended
//! prompts to the user.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const MAX_CHOICES = 4;

/// ClarifyTool - Ask user clarifying questions
pub const ClarifyTool = struct {
    pub const tool_name = "clarify";
    pub const tool_description = "Ask the user a question when you need clarification, feedback, or a decision before proceeding. Supports two modes: multiple choice (up to 4 choices) or open-ended.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"question\":{\"type\":\"string\",\"description\":\"The question to present to the user\"},\"choices\":{\"type\":\"array\",\"items\":{\"type\":\"string\"},\"maxItems\":4,\"description\":\"Up to 4 answer choices. Omit for open-ended question.\"}},\"required\":[\"question\"]}";

    pub fn tool(self: *ClarifyTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *ClarifyTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const question = root.getString(args, "question") orelse {
            return ToolResult.fail("question is required");
        };

        // Validate question is not empty
        const trimmed_question = std.mem.trim(u8, question, " \t\n");
        if (trimmed_question.len == 0) {
            return ToolResult.fail("Question text cannot be empty");
        }

        // Get optional choices
        var choices_opt: ?[]const []const u8 = null;
        if (args.get("choices")) |choices_val| {
            if (choices_val == .array) {
                const arr = choices_val.array;
                // Limit to MAX_CHOICES
                const count = @min(arr.items.len, MAX_CHOICES);
                if (count > 0) {
                    var choices: std.ArrayList([]const u8) = .empty;
                    defer choices.deinit(allocator);
                    for (arr.items[0..count]) |item| {
                        if (item == .string) {
                            const trimmed = std.mem.trim(u8, item.string, " \t\n");
                            if (trimmed.len > 0) {
                                choices.append(allocator, trimmed) catch continue;
                            }
                        }
                    }
                    if (choices.items.len > 0) {
                        choices_opt = choices.toOwnedSlice(allocator) catch null;
                    }
                }
            }
        }

        // Build response
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(allocator);

        try buf.appendSlice(allocator, "{\"question\":\"");
        try buf.appendSlice(allocator, question);
        try buf.appendSlice(allocator, "\",\"choices_offered\":");

        if (choices_opt) |choices| {
            try buf.appendSlice(allocator, "[");
            for (choices, 0..) |choice, i| {
                if (i > 0) try buf.appendSlice(allocator, ",");
                const c = try std.fmt.allocPrint(allocator, "\"{s}\"", .{choice});
                defer allocator.free(c);
                try buf.appendSlice(allocator, c);
            }
            try buf.appendSlice(allocator, "]");
            allocator.free(choices);
        } else {
            try buf.appendSlice(allocator, "null");
        }

        try buf.appendSlice(allocator, ",\"message\":\"Clarify tool requires platform interaction.\"}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
