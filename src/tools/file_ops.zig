//! File operation tools - read, write, list, search
//! Implements Tool vtable interface

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const shared = @import("../shared/root.zig");
const validation = @import("../validation.zig");

// ── FileReadTool ─────────────────────────────────────────────────────────────────

pub const FileReadTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "read_file";
    pub const tool_description = "Read the contents of a file";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Relative path to the file\"}},\"required\":[\"path\"]}";

    pub fn tool(self: *FileReadTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *FileReadTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = getString(args, "path") orelse {
            return ToolResult.fail("path is required");
        };

        validation.validatePath(path) catch {
            return ToolResult.fail("Invalid or unsafe path");
        };

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.workspace_dir, path });
        defer allocator.free(full_path);

        const content = shared.context.cwdReadFileAlloc(allocator, full_path, 1024 * 1024) catch {
            return ToolResult.fail("Failed to read file");
        };

        return ToolResult.ok(content);
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── FileWriteTool ─────────────────────────────────────────────────────────────────

pub const FileWriteTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "write_file";
    pub const tool_description = "Write content to a file";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Relative path to the file\"},\"content\":{\"type\":\"string\",\"description\":\"Content to write\"}},\"required\":[\"path\",\"content\"]}";

    pub fn tool(self: *FileWriteTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *FileWriteTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = getString(args, "path") orelse {
            return ToolResult.fail("path is required");
        };
        const content = getString(args, "content") orelse {
            return ToolResult.fail("content is required");
        };

        validation.validatePath(path) catch {
            return ToolResult.fail("Invalid or unsafe path");
        };

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.workspace_dir, path });
        defer allocator.free(full_path);

        shared.context.cwdWriteFile(full_path, content) catch {
            return ToolResult.fail("Failed to write file");
        };

        return ToolResult.ok("File written successfully");
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── ListDirectoryTool ─────────────────────────────────────────────────────────────────

pub const ListDirectoryTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "list_directory";
    pub const tool_description = "List files and directories";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Relative path to directory (default: .)\"}},\"required\":[]}";

    pub fn tool(self: *ListDirectoryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *ListDirectoryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = getString(args, "path") orelse ".";

        validation.validatePath(path) catch {
            return ToolResult.fail("Invalid or unsafe path");
        };

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.workspace_dir, path });
        defer allocator.free(full_path);

        var dir = shared.context.cwdOpenDir(full_path, .{}) catch {
            return ToolResult.fail("Failed to open directory");
        };
        defer dir.close(shared.context.io());

        var entries: std.ArrayList(u8) = .empty;
        defer entries.deinit(allocator);

        var iterator = dir.iterate();
        while (iterator.next(shared.context.io()) catch null) |entry| {
            if (entries.items.len > 0) try entries.appendSlice(allocator, "| | |");
            try entries.appendSlice(allocator, entry.name);
        }

        return ToolResult.ok(entries.items);
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── GrepTool ─────────────────────────────────────────────────────────────────

pub const GrepTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "grep";
    pub const tool_description = "Search for pattern in file";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"path\":{\"type\":\"string\",\"description\":\"Relative path to file\"},\"pattern\":{\"type\":\"string\",\"description\":\"Pattern to search for\"}},\"required\":[\"path\",\"pattern\"]}";

    pub fn tool(self: *GrepTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *GrepTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const path = getString(args, "path") orelse {
            return ToolResult.fail("path is required");
        };
        const pattern = getString(args, "pattern") orelse {
            return ToolResult.fail("pattern is required");
        };

        validation.validatePath(path) catch {
            return ToolResult.fail("Invalid or unsafe path");
        };

        const full_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.workspace_dir, path });
        defer allocator.free(full_path);

        const content = shared.context.cwdReadFileAlloc(allocator, full_path, 1024 * 1024) catch {
            return ToolResult.fail("Failed to read file");
        };

        var results = std.ArrayList(u8).empty;
        defer results.deinit(allocator);

        var lines = std.mem.splitScalar(u8, content, '\n');
        var line_num: usize = 0;
        while (lines.next()) |line| : (line_num += 1) {
            if (std.mem.indexOf(u8, line, pattern) != null) {
                var num_buf: [32]u8 = undefined;
                const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{line_num}) catch "";
                try results.appendSlice(allocator, num_str);
                try results.appendSlice(allocator, ":");
                try results.appendSlice(allocator, line);
                try results.append(allocator, '\n');
            }
        }

        return ToolResult.ok(try results.toOwnedSlice(allocator));
    }

    pub const vtable = root.ToolVTable(@This());
};

// ── GlobTool ───────────────────────────────────────────────────────────────────

pub const GlobTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "glob";
    pub const tool_description = "Find files matching a pattern in the workspace";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"pattern\":{\"type\":\"string\",\"description\":\"Glob pattern to match (e.g., *.zig)\"}},\"required\":[\"pattern\"]}";

    pub fn tool(self: *GlobTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *GlobTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const pattern = getString(args, "pattern") orelse {
            return ToolResult.fail("pattern is required");
        };

        validation.validatePath(pattern) catch {
            return ToolResult.fail("Invalid or unsafe pattern");
        };

        var dir = shared.context.cwdOpenDir(self.workspace_dir, .{}) catch {
            return ToolResult.fail("Failed to open workspace directory");
        };
        defer dir.close(shared.context.io());

        var results = std.ArrayList(u8).empty;
        defer results.deinit(allocator);

        var count: usize = 0;
        try self.walkRecursive(dir, allocator, "", pattern, &results, &count);

        if (count == 0) {
            return ToolResult.ok("No files found matching pattern");
        }

        return ToolResult.ok(try results.toOwnedSlice(allocator));
    }

    fn walkRecursive(self: *GlobTool, dir: std.Io.Dir, allocator: std.mem.Allocator, prefix: []const u8, pattern: []const u8, results: *std.ArrayList(u8), count: *usize) !void {
        var iterator = dir.iterate();
        while (iterator.next(shared.context.io()) catch null) |entry| {
            const full_path = if (prefix.len > 0)
                try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, entry.name })
            else
                try allocator.dupe(u8, entry.name);
            defer allocator.free(full_path);

            switch (entry.kind) {
                .file => {
                    if (matchesGlobPattern(entry.name, pattern)) {
                        if (count.* > 0) try results.appendSlice(allocator, "\n");
                        try results.appendSlice(allocator, full_path);
                        count.* += 1;
                        if (count.* >= 100) return;
                    }
                },
                .directory => {
                    var subdir = dir.openDir(shared.context.io(), entry.name, .{}) catch continue;
                    defer subdir.close(shared.context.io());
                    try self.walkRecursive(subdir, allocator, full_path, pattern, results, count);
                },
                else => {},
            }
        }
    }

    pub const vtable = root.ToolVTable(@This());
};

/// Simple glob pattern matching (supports * wildcard)
fn matchesGlobPattern(name: []const u8, pattern: []const u8) bool {
    if (std.mem.eql(u8, pattern, "*")) return true;
    if (std.mem.indexOfScalar(u8, pattern, '*')) |_| {
        var parts = std.mem.splitScalar(u8, pattern, '*');
        const before = parts.first();
        const after = parts.rest();
        if (name.len >= before.len and name.len >= after.len) {
            const has_prefix = if (before.len > 0) std.mem.eql(u8, name[0..before.len], before) else true;
            const has_suffix = if (after.len > 0) std.mem.eql(u8, name[name.len - after.len ..], after) else true;
            return has_prefix and has_suffix;
        }
        return false;
    }
    return std.mem.eql(u8, name, pattern);
}
