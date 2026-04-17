//! Git tool - Git operations for repository management
//!
//! Implements git clone, status, log, diff, add, commit, push, pull, branch operations

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;
const getString = root.getString;
const shared = @import("../shared/root.zig");

pub const GitTool = struct {
    workspace_dir: []const u8,

    pub const tool_name = "git";
    pub const tool_description = "Execute git commands for version control operations";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"operation\":{\"type\":\"string\",\"description\":\"Git operation: clone, status, log, diff, add, commit, push, pull, branch, checkout, fetch, current\"},\"repo_url\":{\"type\":\"string\",\"description\":\"Repository URL for clone operation\"},\"path\":{\"type\":\"string\",\"description\":\"Path within workspace (default: root)\"},\"message\":{\"type\":\"string\",\"description\":\"Commit message for commit operation\"},\"branch\":{\"type\":\"string\",\"description\":\"Branch name for branch/checkout operations\"},\"remote\":{\"type\":\"string\",\"description\":\"Remote name (default: origin)\"}},\"required\":[\"operation\"]}";

    pub fn tool(self: *GitTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *GitTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const operation = getString(args, "operation") orelse return ToolResult.fail("operation required");

        const path = getString(args, "path") orelse self.workspace_dir;
        const repo_url = getString(args, "repo_url");
        const message = getString(args, "message");
        const branch = getString(args, "branch");
        const remote = getString(args, "remote") orelse "origin";

        if (!isPathSafe(path, self.workspace_dir)) {
            return ToolResult.fail("Path outside workspace is not allowed");
        }

        if (std.mem.eql(u8, operation, "clone")) {
            if (repo_url) |url| {
                const result = try std.process.run(allocator, shared.context.io(), .{
                    .argv = &.{ "git", "clone", url },
                    .cwd = .{ .path = path },
                });
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.term.exited != 0) {
                    return ToolResult.fail(result.stderr);
                }
                return ToolResult.ok("Repository cloned successfully");
            }
            return ToolResult.fail("repo_url required for clone");
        } else if (std.mem.eql(u8, operation, "status")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "status", "--porcelain" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            return ToolResult.ok(result.stdout);
        } else if (std.mem.eql(u8, operation, "log")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "log", "--oneline", "-20" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            return ToolResult.ok(result.stdout);
        } else if (std.mem.eql(u8, operation, "diff")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "diff", "--stat" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            return ToolResult.ok(result.stdout);
        } else if (std.mem.eql(u8, operation, "add")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "add", "." },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term.exited != 0) {
                return ToolResult.fail(result.stderr);
            }
            return ToolResult.ok("Changes staged");
        } else if (std.mem.eql(u8, operation, "commit")) {
            if (message) |msg| {
                const result = try std.process.run(allocator, shared.context.io(), .{
                    .argv = &.{ "git", "commit", "-m", msg },
                    .cwd = .{ .path = path },
                });
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.term.exited != 0) {
                    return ToolResult.fail(result.stderr);
                }
                return ToolResult.ok("Changes committed");
            }
            return ToolResult.fail("message required for commit");
        } else if (std.mem.eql(u8, operation, "push")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "push", remote, "HEAD" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term.exited != 0) {
                return ToolResult.fail(result.stderr);
            }
            return ToolResult.ok("Pushed to remote");
        } else if (std.mem.eql(u8, operation, "pull")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "pull", remote },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term.exited != 0) {
                return ToolResult.fail(result.stderr);
            }
            return ToolResult.ok("Pulled from remote");
        } else if (std.mem.eql(u8, operation, "branch")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "branch", "-a" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            return ToolResult.ok(result.stdout);
        } else if (std.mem.eql(u8, operation, "checkout")) {
            if (branch) |b| {
                const result = try std.process.run(allocator, shared.context.io(), .{
                    .argv = &.{ "git", "checkout", b },
                    .cwd = .{ .path = path },
                });
                defer allocator.free(result.stdout);
                defer allocator.free(result.stderr);
                if (result.term.exited != 0) {
                    return ToolResult.fail(result.stderr);
                }
                return ToolResult.ok("Checked out branch");
            }
            return ToolResult.fail("branch required for checkout");
        } else if (std.mem.eql(u8, operation, "fetch")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "fetch", "--all" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            if (result.term.exited != 0) {
                return ToolResult.fail(result.stderr);
            }
            return ToolResult.ok("Fetched from all remotes");
        } else if (std.mem.eql(u8, operation, "current")) {
            const result = try std.process.run(allocator, shared.context.io(), .{
                .argv = &.{ "git", "rev-parse", "--abbrev-ref", "HEAD" },
                .cwd = .{ .path = path },
            });
            defer allocator.free(result.stdout);
            defer allocator.free(result.stderr);
            return ToolResult.ok(result.stdout);
        } else {
            return ToolResult.fail("Unknown operation. Use: clone, status, log, diff, add, commit, push, pull, branch, checkout, fetch, current");
        }
    }

    fn isPathSafe(path: []const u8, workspace_dir: []const u8) bool {
        var buf: [1024]u8 = undefined;
        if (path.len >= 4096) return false;
        var path_z: [4096:0]u8 = undefined;
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        const real_path = std.c.realpath(&path_z, &buf) orelse return false;
        return std.mem.startsWith(u8, std.mem.span(real_path), workspace_dir);
    }

    pub const vtable = root.ToolVTable(@This());
};
