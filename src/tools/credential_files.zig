//! Credential files registry for remote terminal backends.
//!
//! Remote backends (Docker, Modal, SSH) create sandboxes with no host files.
//! This module ensures credential files, skill directories, and cache
//! directories are mounted or synced into those sandboxes.
//!
//! Security: Rejects absolute paths and path traversal sequences (..).
//! The resolved host path must remain inside HERMES_HOME.
//!

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const VALID_STATUSES = &[_][]const u8{ "pending", "in_progress", "completed", "cancelled" };

/// A mount entry mapping host path to container path
pub const MountEntry = struct {
    host_path: []const u8,
    container_path: []const u8,
};

/// Registered credential files (host_path -> container_path)
var cred_lock = std.Thread.Mutex{};
var registered_files: std.StringArrayHashMap([]const u8) = .empty;

/// Default container base path
const DEFAULT_CONTAINER_BASE = "/root/.hermes";

/// Check if path is absolute (Unix-style)
fn isAbsolutePath(path: []const u8) bool {
    return path.len > 0 and path[0] == '/';
}

/// Check for path traversal sequences
fn hasPathTraversal(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "..") != null;
}

/// Normalize and validate a path, ensuring it stays within base
fn validateAndNormalizePath(rel_path: []const u8, base_path: []const u8) ?[]const u8 {
    // Reject absolute paths
    if (isAbsolutePath(rel_path)) {
        std.debug.print("credential_files: rejected absolute path: {s}\n", .{rel_path});
        return null;
    }

    // Reject path traversal
    if (hasPathTraversal(rel_path)) {
        std.debug.print("credential_files: rejected path traversal: {s}\n", .{rel_path});
        return null;
    }

    // Build full path
    if (rel_path.len == 0) return null;

    var full_path = std.array_list.AlignedManaged(u8, null).init(std.heap.page_allocator);
    defer full_path.deinit();

    // Start with base
    full_path.appendSlice(base_path) catch return null;
    if (full_path.items[full_path.items.len - 1] != '/') {
        full_path.append('/') catch return null;
    }
    full_path.appendSlice(rel_path) catch return null;

    return full_path.toOwnedSlice();
}

/// Register a credential file for mounting into remote sandboxes
/// relative_path is relative to HERMES_HOME
/// Returns true if the file exists and was registered
pub fn registerCredentialFile(relative_path: []const u8, container_base: []const u8) bool {
    // In a full implementation, we'd resolve HERMES_HOME
    // For now, use a default path
    const hermes_home = std.os.getenv("HERMES_HOME") orelse "/Users/n0x/.hermes";

    const validated = validateAndNormalizePath(relative_path, hermes_home) orelse return false;

    // Check if file exists
    const file = std.fs.openFileAbsolute(validated, .{}) catch return false;
    defer file.close();

    // Build container path
    var container_path = std.array_list.AlignedManaged(u8, null).init(std.heap.page_allocator);
    defer container_path.deinit();

    container_path.appendSlice(container_base) catch return false;
    if (container_path.items[container_path.items.len - 1] != '/') {
        container_path.append('/') catch return false;
    }
    container_path.appendSlice(relative_path) catch return false;

    // Register
    cred_lock.lock();
    defer cred_lock.unlock();

    if (registered_files.get(container_path.items)) |_| {
        // Already registered
        return true;
    }

    registered_files.put(container_path.items, validated) catch return false;
    std.debug.print("credential_files: registered {s} -> {s}\n", .{ validated, container_path.items });

    return true;
}

/// Get all credential file mounts
pub fn getCredentialFileMounts() []const MountEntry {
    cred_lock.lock();
    defer cred_lock.unlock();

    // This would need to return owned memory in a full implementation
    // For now, return empty
    return &.{};
}

/// Clear all registered credential files
pub fn clearCredentialFiles() void {
    cred_lock.lock();
    defer cred_lock.unlock();

    registered_files = .empty;
}

/// CredentialFilesTool - Tool for managing credential file mounts
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
                var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
                defer buf.deinit();
                try buf.writer().print("{{\"success\":{},\"path\":\"{s}\"}}", .{ success, path });
                return ToolResult{
                    .success = true,
                    .output = try buf.toOwnedSlice(allocator),
                };
            }
            return ToolResult.fail("relative_path required for register action");
        } else if (std.mem.eql(u8, action, "list")) {
            // List all mounts
            var buf = std.array_list.AlignedManaged(u8, null).init(allocator);
            defer buf.deinit();
            const w = buf.writer();

            try w.writeAll("{\"mounts\":[");
            cred_lock.lock();
            var first = true;
            var it = registered_files.iterator();
            while (it.next()) |entry| {
                if (!first) try w.writeAll(",");
                try w.print("{{\"container_path\":\"{s}\",\"host_path\":\"{s}\"}}", .{ entry.key_ptr.*, entry.value_ptr.* });
                first = false;
            }
            cred_lock.unlock();
            try w.writeAll("]}");

            return ToolResult{
                .success = true,
                .output = try buf.toOwnedSlice(allocator),
            };
        } else if (std.mem.eql(u8, action, "clear")) {
            clearCredentialFiles();
            return ToolResult.ok("{\"success\":true,\"message\":\"Credential files cleared\"}");
        }

        return ToolResult.fail("Unknown action. Use: register, list, clear");
    }

    pub const vtable = root.ToolVTable(@This());
};
