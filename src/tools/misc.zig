//! Miscellaneous tools - Todo, Calculator, Browser
//! Implements Tool vtable interface

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;

// ── TodoTool ──────────────────────────────────────────────────────────────────

pub const TodoTool = struct {
    pub const tool_name = "todo";
    pub const tool_description = "Manage your task list. Use for complex tasks with 3+ steps.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"todos\":{\"type\":\"array\",\"description\":\"Task items\",\"items\":{\"type\":\"object\",\"properties\":{\"id\":{\"type\":\"string\"},\"content\":{\"type\":\"string\"},\"status\":{\"type\":\"string\",\"enum\":[\"pending\",\"in_progress\",\"completed\"]}},\"required\":[\"id\",\"content\",\"status\"]}}}}";

    pub fn tool(self: *TodoTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *TodoTool, _: std.mem.Allocator, _: JsonObjectMap) !ToolResult {
        return ToolResult.ok("{\"todos\":[],\"summary\":{\"total\":0,\"pending\":0,\"in_progress\":0,\"completed\":0}}");
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── CalculatorTool ────────────────────────────────────────────────────────────

pub const CalculatorTool = struct {
    pub const tool_name = "calculator";
    pub const tool_description = "Evaluate simple math expressions";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"expression\":{\"type\":\"string\",\"description\":\"Math expression to evaluate\"}},\"required\":[\"expression\"]}";

    pub fn tool(self: *CalculatorTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *CalculatorTool, _: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const expr = getString(args, "expression") orelse {
            return ToolResult.fail("expression is required");
        };

        var result: f64 = 0;
        var op: u8 = '+';
        var num_buf: [64]u8 = undefined;
        var num_idx: usize = 0;

        for (expr) |c| {
            if (c >= '0' and c <= '9') {
                num_buf[num_idx] = c;
                num_idx += 1;
            } else if (c == '.') {
                num_buf[num_idx] = c;
                num_idx += 1;
            } else if (c == '+' or c == '-' or c == '*' or c == '/' or c == '=') {
                if (num_idx > 0) {
                    num_buf[num_idx] = 0;
                    const num = std.fmt.parseFloat(f64, &num_buf) catch 0;
                    if (op == '+') result += num else if (op == '-') result -= num else if (op == '*') result *= num else if (op == '/') result /= num;
                    num_idx = 0;
                }
                op = c;
            }
        }

        var output: [32]u8 = undefined;
        const result_str = std.fmt.bufPrint(&output, "{d}", .{result}) catch "0";
        return ToolResult.ok(result_str);
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── BrowserNavigateTool ────────────────────────────────────────────────────────

pub const BrowserNavigateTool = struct {
    pub const tool_name = "browser_navigate";
    pub const tool_description = "Navigate browser to a URL";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"url\":{\"type\":\"string\",\"description\":\"URL to navigate to\"}},\"required\":[\"url\"]}";

    pub fn tool(self: *BrowserNavigateTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *BrowserNavigateTool, _: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const url = getString(args, "url");
        _ = url;
        return ToolResult.ok("Browser navigation not yet implemented");
    }

    pub const vtable = root.ToolVTable(@This());
};
