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
                    var choices = std.array_list.AlignedManaged([]const u8, null).init(allocator);
                    errdefer choices.deinit();
                    for (arr.items[0..count]) |item| {
                        if (item == .string) {
                            const trimmed = std.mem.trim(u8, item.string, " \t\n");
                            if (trimmed.len > 0) {
                                try choices.append(trimmed);
                            }
                        }
                    }
                    if (choices.items.len > 0) {
                        choices_opt = try choices.toOwnedSlice();
                    }
                }
            }
        }

        // Build response
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"question\":\"");
        try w.writeAll(question);
        try w.writeAll("\",\"choices_offered\":");

        if (choices_opt) |choices| {
            try w.writeAll("[");
            for (choices, 0..) |choice, i| {
                if (i > 0) try w.writeAll(",");
                try w.print("\"{s}\"", .{choice});
            }
            try w.writeAll("]");
            allocator.free(choices);
        } else {
            try w.writeAll("null");
        }

        try w.writeAll(",\"message\":\"Clarify tool requires platform integration. In CLI mode, use terminal for user interaction.\"}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
