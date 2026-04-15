const std = @import("std");

/// ANSI color codes for terminal output
pub const Colors = struct {
    pub const reset = "\x1b[0m";
    pub const bold = "\x1b[1m";
    pub const dim = "\x1b[2m";
    pub const red = "\x1b[31m";
    pub const green = "\x1b[32m";
    pub const yellow = "\x1b[33m";
    pub const blue = "\x1b[34m";
    pub const magenta = "\x1b[35m";
    pub const cyan = "\x1b[36m";
    pub const white = "\x1b[37m";
};

/// Output styles
pub const Style = enum {
    user,
    assistant,
    system,
    tool,
    err,  // 'error' is a keyword
    success,
    info,
};

/// Formatted output writer
pub const Display = struct {
    allocator: std.mem.Allocator,
    use_colors: bool = true,

    pub fn init(allocator: std.mem.Allocator) Display {
        return .{ .allocator = allocator };
    }

    /// Print a styled message
    pub fn print(self: *const Display, style: Style, message: []const u8) void {
        if (self.use_colors) {
            const color = switch (style) {
                .user => Colors.cyan,
                .assistant => Colors.green,
                .system => Colors.yellow,
                .err => Colors.red,
                .success => Colors.green,
                .info => Colors.blue,
            };
            std.debug.print("{s}{s}{s}{s}", .{ color, stylePrefix(style), message, Colors.reset });
        } else {
            std.debug.print("{s}{s}", .{ stylePrefix(style), message });
        }
    }

    /// Print user input prompt
    pub fn printPrompt(_: *const Display) void {
        std.debug.print("{s}> {s}", .{ Colors.blue, Colors.reset });
    }

    /// Print a header
    pub fn printHeader(self: *const Display, title: []const u8) void {
        if (self.use_colors) {
            std.debug.print("\n{s}{s}{s}{s}\n", .{ Colors.bold, Colors.blue, title, Colors.reset });
        } else {
            std.debug.print("\n=== {s} ===\n", .{title});
        }
    }

    /// Print a separator line
    pub fn printSeparator(self: *const Display) void {
        if (self.use_colors) {
            std.debug.print("{s}{s}{s}\n", .{ Colors.dim, "─".repeat(60), Colors.reset });
        } else {
            std.debug.print("{}\n", .{"=".repeat(60)});
        }
    }

    /// Print usage statistics
    pub fn printUsageStats(self: *const Display, prompt_tokens: u32, completion_tokens: u32, cost: f64) void {
        if (self.use_colors) {
            std.debug.print(
                "{s}Usage:{s} {d} prompt + {d} completion = {d} total tokens (${d:.4f})\n",
                .{ Colors.dim, Colors.reset, prompt_tokens, completion_tokens, prompt_tokens + completion_tokens, cost },
            );
        } else {
            std.debug.print(
                "Usage: {} prompt + {} completion = {} total tokens (${:.4f})\n",
                .{ prompt_tokens, completion_tokens, prompt_tokens + completion_tokens, cost },
            );
        }
    }

    fn stylePrefix(style: Style) []const u8 {
        return switch (style) {
            .user => "[User] ",
            .assistant => "",
            .system => "[System] ",
            .tool => "[Tool] ",
            .err => "[ERROR] ",
            .success => "[OK] ",
            .info => "[INFO] ",
        };
    }
};

/// Extension to print repeated characters
pub fn repeat(comptime char: []const u8, comptime count: usize) []const u8 {
    comptime var result: [char.len * count]u8 = undefined;
    inline for (0..count) |i| {
        @memcpy(result[i * char.len ..][0..char.len], char);
    }
    return &result;
}
