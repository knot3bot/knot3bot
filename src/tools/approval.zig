//! Dangerous command approval and detection tool
//! Prevents execution of potentially harmful commands

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

/// Result of dangerous command check
pub const ApprovalResult = struct {
    approved: bool,
    pattern_key: ?[]const u8 = null,
    description: ?[]const u8 = null,
};

/// Dangerous pattern entry
const PatternEntry = struct {
    pattern: []const u8,
    description: []const u8,
};

/// All dangerous patterns to detect
const DANGEROUS_PATTERNS = [_]PatternEntry{
    .{ .pattern = "rm -rf /", .description = "delete root directory" },
    .{ .pattern = "rm -rf /*", .description = "delete root directory" },
    .{ .pattern = "rm -r /", .description = "recursive delete from root" },
    .{ .pattern = "rm --recursive /", .description = "recursive delete from root" },
    .{ .pattern = "chmod 777", .description = "chmod 777 permissions" },
    .{ .pattern = "chmod 666", .description = "chmod 666 permissions" },
    .{ .pattern = "chmod -R 777", .description = "recursive chmod 777" },
    .{ .pattern = "DROP TABLE", .description = "SQL DROP TABLE" },
    .{ .pattern = "DROP DATABASE", .description = "SQL DROP DATABASE" },
    .{ .pattern = "DELETE FROM", .description = "SQL DELETE" },
    .{ .pattern = "TRUNCATE TABLE", .description = "SQL TRUNCATE" },
    .{ .pattern = "mkfs", .description = "format filesystem" },
    .{ .pattern = "dd if=", .description = "disk copy operation" },
    .{ .pattern = "> /dev/sd", .description = "write to block device" },
    .{ .pattern = ":(){ :|:& };:", .description = "fork bomb" },
    .{ .pattern = "curl | sh", .description = "pipe remote to shell" },
    .{ .pattern = "wget | sh", .description = "pipe remote to shell" },
    .{ .pattern = "bash -c", .description = "shell -c execution" },
    .{ .pattern = "sh -c", .description = "shell -c execution" },
    .{ .pattern = "kill -9 -1", .description = "kill all processes" },
    .{ .pattern = "pkill -9", .description = "force kill processes" },
    .{ .pattern = "sed -i", .description = "sed in-place edit" },
    .{ .pattern = "> /etc/", .description = "overwrite system config" },
    .{ .pattern = "chown -R root", .description = "recursive chown to root" },
    .{ .pattern = "systemctl stop", .description = "stop system service" },
    .{ .pattern = "systemctl disable", .description = "disable system service" },
};

/// Check if a command is dangerous
pub fn checkDangerousCommand(command: []const u8) ApprovalResult {
    // Simple lowercase comparison
    for (DANGEROUS_PATTERNS) |entry| {
        if (containsLower(command, entry.pattern)) {
            return .{
                .approved = false,
                .pattern_key = entry.description,
                .description = entry.description,
            };
        }
    }

    return .{ .approved = true };
}

/// Case-insensitive contains check
fn containsLower(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            const h = std.ascii.toLower(haystack[i + j]);
            const n = std.ascii.toLower(needle[j]);
            if (h != n) break;
            if (j == needle.len - 1) return true;
        }
    }
    return false;
}

/// ApprovalTool - Tool for checking dangerous commands
pub const ApprovalTool = struct {
    pub const tool_name = "approval";
    pub const tool_description = "Check if a command is dangerous and requires approval before execution";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"command\":{\"type\":\"string\",\"description\":\"The shell command to check for dangerous patterns\"}},\"required\":[\"command\"]}";

    pub fn tool(self: *ApprovalTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *ApprovalTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const command = root.getString(args, "command") orelse {
            return ToolResult.fail("command is required");
        };

        const result = checkDangerousCommand(command);

        // Build JSON response manually
        var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
        errdefer buf.deinit();
        const w = buf.writer();

        try w.writeAll("{\"approved\":");
        if (result.approved) {
            try w.writeAll("true");
        } else {
            try w.writeAll("false");
        }
        try w.writeAll(",\"pattern_key\":");
        if (result.pattern_key) |key| {
            try w.print("\"{s}\"", .{key});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(",\"description\":");
        if (result.description) |desc| {
            try w.print("\"{s}\"", .{desc});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll("}");

        return ToolResult{
            .success = true,
            .output = try buf.toOwnedSlice(allocator),
        };
    }

    pub const vtable = root.ToolVTable(@This());
};
