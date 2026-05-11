//! Credential files registry for remote terminal backends.
//!
//! Remote backends (Docker, Modal, SSH) create sandboxes with no host files.
//! This module ensures credential files, skill directories, and cache
//! directories are mounted or synced into those sandboxes.
//!
//! Security: Rejects absolute paths and path traversal sequences (..).
//! The resolved host path must remain inside HERMES_HOME.

const std = @import("std");
const root = @import("root.zig");
const shared = @import("../shared/context.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const DEFAULT_CONTAINER_BASE = "/root/.hermes";

pub const MountEntry = struct {
    host_path: []const u8,
    container_path: []const u8,
};

var cred_lock: std.Io.Mutex = std.Io.Mutex.init;
var registered_files: std.StringHashMap([]const u8) = std.StringHashMap([]const u8).init(std.heap.page_allocator);

fn isAbsolutePath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

fn hasPathTraversal(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "..") != null;
}

fn validateAndNormalizePath(rel_path: []const u8, base_path: []const u8) ?[]const u8 {
    if (isAbsolutePath(rel_path)) {
        std.debug.print("credential_files: rejected absolute path: {s}\n", .{rel_path});
        return null;
    }
    if (hasPathTraversal(rel_path)) {
        std.debug.print("credential_files: rejected path traversal: {s}\n", .{rel_path});
        return null;
    }
    if (rel_path.len == 0) return null;

    var full_path = std.array_list.AlignedManaged(u8, null).init(std.heap.page_allocator);
    full_path.appendSlice(base_path) catch return null;
    if (full_path.items[full_path.items.len - 1] != '/') {
        full_path.append('/') catch return null;
    }
    full_path.appendSlice(rel_path) catch return null;
    return full_path.toOwnedSlice() catch null;
}

pub fn registerCredentialFile(relative_path: []const u8, container_base: []const u8) bool {
    const hermes_home = shared.getenv("HERMES_HOME") orelse "/Users/n0x/.hermes";
    const validated = validateAndNormalizePath(relative_path, hermes_home) orelse return false;

    const io_instance = shared.io();
    const file = std.Io.Dir.openFileAbsolute(io_instance, validated, .{}) catch return false;
    file.close(io_instance);

    var container_path = std.array_list.AlignedManaged(u8, null).init(std.heap.page_allocator);
    container_path.appendSlice(container_base) catch return false;
    if (container_path.items[container_path.items.len - 1] != '/') {
        container_path.append('/') catch return false;
    }
    container_path.appendSlice(relative_path) catch return false;

    const io = shared.io();
    cred_lock.lockUncancelable(io);
    defer cred_lock.unlock(io);

    if (registered_files.get(container_path.items)) |_| {
        return true;
    }

    const owned_key = container_path.toOwnedSlice() catch return false;
    registered_files.put(owned_key, validated) catch return false;
    std.debug.print("credential_files: registered {s} -> {s}\n", .{ validated, container_path.items });
    return true;
}

pub fn getCredentialFileMounts() []const MountEntry {
    const io = shared.io();
    cred_lock.lockUncancelable(io);
    defer cred_lock.unlock(io);
    return &.{};
}

pub fn clearCredentialFiles() void {
    const io = shared.io();
    cred_lock.lockUncancelable(io);
    defer cred_lock.unlock(io);
    registered_files = std.StringHashMap([]const u8).init(std.heap.page_allocator);
}

pub const CredentialFilesTool = struct {
    pub const tool_name = "credential_files";
    pub const tool_description = "Manage credential files for mounting into remote sandboxes. Register files that should be available in containerized environments.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"register\",\"list\",\"clear\"],\"description\":\"Action: 'register' a file, 'list' all mounts, 'clear' all\"},\"relative_path\":{\"type\":\"string\",\"description\":\"Path relative to HERMES_HOME to register\"},\"container_base\":{\"type\":\"string\",\"description\":\"Base path in container (default: /root/.hermes)\"}},\"required\":[\"action\"]}";

    pub fn tool(self: *CredentialFilesTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(_: *CredentialFilesTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse "list";
        const relative_path = root.getString(args, "relative_path");
        const container_base = root.getString(args, "container_base") orelse DEFAULT_CONTAINER_BASE;

        if (std.mem.eql(u8, action, "register")) {
            if (relative_path) |path| {
                const success = registerCredentialFile(path, container_base);
                const resp = try std.fmt.allocPrint(allocator, "{{\"success\":{},\"path\":\"{s}\"}}", .{ success, path });
                return ToolResult.ok(resp);
            }
            return ToolResult.fail("relative_path required for register action");
        } else if (std.mem.eql(u8, action, "list")) {
            var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
            defer buf.deinit();

            try buf.appendSlice("{\"mounts\":[");
            const io = shared.io();
            cred_lock.lockUncancelable(io);
            var first = true;
            var it = registered_files.iterator();
            while (it.next()) |entry| {
                if (!first) try buf.appendSlice(",");
                const line = try std.fmt.allocPrint(allocator, "{{\"container_path\":\"{s}\",\"host_path\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.* });
                defer allocator.free(line);
                try buf.appendSlice(line);
                first = false;
            }
            cred_lock.unlock(io);
            try buf.appendSlice("]}");
            return ToolResult.ok(try buf.toOwnedSlice());
        } else if (std.mem.eql(u8, action, "clear")) {
            clearCredentialFiles();
            return ToolResult.ok("{\"success\":true,\"message\":\"Credential files cleared\"}");
        }
        return ToolResult.fail("Unknown action. Use: register, list, clear");
    }

    pub const vtable = root.ToolVTable(@This());
};
