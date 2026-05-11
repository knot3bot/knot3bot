//! Memory Tool - Persistent Curated Memory
//!
//! Provides bounded, file-backed memory that persists across sessions. Two stores:
//!   - MEMORY.md: agent's personal notes and observations
//!   - USER.md: what the agent knows about the user
//!
//! Entry delimiter: § (section sign). Entries can be multiline.

const std = @import("std");
const root = @import("root.zig");
const shared = @import("../shared/context.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const ENTRY_DELIMITER = "\n§\n";
const DEFAULT_MEMORY_CHAR_LIMIT = 2200;
const DEFAULT_USER_CHAR_LIMIT = 1375;

const INVISIBLE_CHARS = [_]u16{
    0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF,
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
};

const THREAT_PATTERNS = [_]struct { pattern: []const u8, name: []const u8 }{
    .{ .pattern = "ignore\\s+(previous|all|above|prior)\\s+instructions", .name = "prompt_injection" },
    .{ .pattern = "you\\s+are\\s+now\\s+", .name = "role_hijack" },
    .{ .pattern = "do\\s+not\\s+tell\\s+the\\s+user", .name = "deception_hide" },
    .{ .pattern = "system\\s+prompt\\s+override", .name = "sys_prompt_override" },
    .{ .pattern = "disregard\\s+(your|all|any)\\s+(instructions|rules|guidelines)", .name = "disregard_rules" },
    .{ .pattern = "act\\s+as\\s+(if|though)\\s+you\\s+(have\\s+no|don't\\s+have)\\s+(restrictions|limits|rules)", .name = "bypass_restrictions" },
    .{ .pattern = "curl\\s+[^\\n]*\\$\\{?\\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)", .name = "exfil_curl" },
    .{ .pattern = "wget\\s+[^\\n]*\\$\\{?\\w*(KEY|TOKEN|SECRET|PASSWORD|CREDENTIAL|API)", .name = "exfil_wget" },
    .{ .pattern = "cat\\s+[^\\n]*(\\.env|credentials|\\.netrc|\\.pgpass|\\.npmrc|\\.pypirc)", .name = "read_secrets" },
    .{ .pattern = "authorized_keys", .name = "ssh_backdoor" },
    .{ .pattern = "\\$HOME/\\.ssh|~/\\.ssh", .name = "ssh_access" },
    .{ .pattern = "\\$HOME/\\.hermes/\\.env|~/\\.hermes/\\.env", .name = "hermes_env" },
};

fn scanMemoryContent(allocator: std.mem.Allocator, content: []const u8) ?[]const u8 {
    for (INVISIBLE_CHARS) |char| {
        const char_str = [_]u8{ @truncate(char), @truncate(char >> 8) };
        if (std.mem.indexOf(u8, content, &char_str) != null) {
            return "Blocked: content contains invisible unicode character (possible injection)";
        }
    }
    for (THREAT_PATTERNS) |threat| {
        if (std.mem.indexOf(u8, content, threat.pattern) != null) {
            return std.fmt.allocPrint(allocator, "Blocked: content matches threat pattern '{s}'", .{threat.name}) catch
                "Blocked: content matches threat pattern";
        }
    }
    return null;
}

pub const MemoryStore = struct {
    memory_entries: std.array_list.AlignedManaged([]const u8, null),
    user_entries: std.array_list.AlignedManaged([]const u8, null),
    memory_char_limit: usize = DEFAULT_MEMORY_CHAR_LIMIT,
    user_char_limit: usize = DEFAULT_USER_CHAR_LIMIT,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MemoryStore {
        return .{
            .memory_entries = std.array_list.AlignedManaged([]const u8, null).init(allocator),
            .user_entries = std.array_list.AlignedManaged([]const u8, null).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MemoryStore) void {
        self.memory_entries.deinit();
        self.user_entries.deinit();
    }

    fn getMemoryDir(self: *MemoryStore) []const u8 {
        const home = shared.getenv("HOME") orelse "/tmp";
        return std.fs.path.join(self.allocator, &.{ home, ".hermes", "memories" }) catch "/tmp/.hermes/memories";
    }

    fn getEntries(self: *MemoryStore, target: []const u8) *std.array_list.AlignedManaged([]const u8, null) {
        if (std.mem.eql(u8, target, "user")) return &self.user_entries;
        return &self.memory_entries;
    }

    fn getCharLimit(self: *MemoryStore, target: []const u8) usize {
        if (std.mem.eql(u8, target, "user")) return self.user_char_limit;
        return self.memory_char_limit;
    }

    fn getPath(self: *MemoryStore, target: []const u8) []const u8 {
        const mem_dir = self.getMemoryDir();
        const filename = if (std.mem.eql(u8, target, "user")) "USER.md" else "MEMORY.md";
        return std.fs.path.join(self.allocator, &.{ mem_dir, filename }) catch
            std.fs.path.join(self.allocator, &.{ "/tmp/.hermes/memories", filename }) catch "/tmp/.hermes/memories/MEMORY.md";
    }

    fn calcCharCount(entries: []const []const u8) usize {
        if (entries.len == 0) return 0;
        var total: usize = 0;
        for (entries) |entry| total += entry.len;
        total += ENTRY_DELIMITER.len * (entries.len - 1);
        return total;
    }

    fn readEntries(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
        var entries = std.array_list.AlignedManaged([]const u8, null).init(allocator);
        errdefer entries.deinit();

        const content = shared.cwdReadFileAlloc(allocator, path, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return entries.toOwnedSlice();
            return err;
        };
        defer allocator.free(content);

        if (content.len == 0) return entries.toOwnedSlice();

        var parts = std.mem.split(u8, content, ENTRY_DELIMITER);
        while (parts.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t\n");
            if (trimmed.len > 0) {
                const copy = try allocator.dupe(u8, trimmed);
                errdefer allocator.free(copy);
                try entries.append(copy);
            }
        }
        return entries.toOwnedSlice();
    }

    fn writeEntries(allocator: std.mem.Allocator, path: []const u8, entries: []const []const u8) !void {
        var content = std.array_list.AlignedManaged(u8, null).init(allocator);
        defer content.deinit();

        for (entries, 0..) |entry, i| {
            if (i > 0) try content.appendSlice(ENTRY_DELIMITER);
            try content.appendSlice(entry);
        }

        const dir = std.fs.path.dirname(path) orelse ".";
        shared.cwdMakePath(dir) catch {};

        const tmp_path = try std.fs.path.join(allocator, &.{ dir, ".mem_tmp" });
        defer allocator.free(tmp_path);

        shared.cwdWriteFile(tmp_path, content.items) catch return;
        shared.cwdRename(tmp_path, path) catch {};
    }

    fn formatSuccessResponse(self: *MemoryStore, target: []const u8) []const u8 {
        const entries = self.getEntries(target);
        const current = MemoryStore.calcCharCount(entries.items);
        const limit = self.getCharLimit(target);
        const pct = @min(100, (current * 100) / @max(1, limit));

        return std.fmt.allocPrint(self.allocator,
            "{{\"success\":true,\"target\":\"{s}\",\"usage\":\"{}% — {}/{}\",\"entry_count\":{}}}",
            .{ target, pct, current, limit, entries.items.len }) catch "{}";
    }

    pub fn add(self: *MemoryStore, target: []const u8, content: []const u8) !ToolResult {
        const trimmed = std.mem.trim(u8, content, " \t\n");
        if (trimmed.len == 0) return ToolResult.fail("Content cannot be empty");

        if (scanMemoryContent(self.allocator, trimmed)) |error_msg| {
            return ToolResult.fail(error_msg);
        }

        const entries = self.getEntries(target);
        const limit = self.getCharLimit(target);

        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry, trimmed)) {
                return ToolResult{ .success = true, .output = self.formatSuccessResponse(target) };
            }
        }

        try entries.append(try self.allocator.dupe(u8, trimmed));

        const new_count = MemoryStore.calcCharCount(entries.items);
        if (new_count > limit) {
            _ = entries.pop();
            const current = MemoryStore.calcCharCount(entries.items);
            const msg = std.fmt.allocPrint(self.allocator, "Memory at {}/{} chars. Adding this entry ({} chars) would exceed the limit. Replace or remove existing entries first.", .{ current, limit, trimmed.len }) catch "Memory limit exceeded";
            return ToolResult.fail(msg);
        }

        const path = self.getPath(target);
        defer self.allocator.free(path);
        MemoryStore.writeEntries(self.allocator, path, entries.items) catch {};

        return ToolResult{ .success = true, .output = self.formatSuccessResponse(target) };
    }

    pub fn replace(self: *MemoryStore, target: []const u8, old_text: []const u8, new_content: []const u8) !ToolResult {
        const trimmed_old = std.mem.trim(u8, old_text, " \t\n");
        const trimmed_new = std.mem.trim(u8, new_content, " \t\n");

        if (trimmed_old.len == 0) return ToolResult.fail("old_text cannot be empty");
        if (trimmed_new.len == 0) return ToolResult.fail("new_content cannot be empty. Use 'remove' to delete entries");

        if (scanMemoryContent(self.allocator, trimmed_new)) |error_msg| {
            return ToolResult.fail(error_msg);
        }

        const entries = self.getEntries(target);
        const limit = self.getCharLimit(target);

        var match_idx: ?usize = null;
        for (entries.items, 0..) |entry, i| {
            if (std.mem.indexOf(u8, entry, trimmed_old) != null) {
                match_idx = i;
                break;
            }
        }

        if (match_idx == null) {
            const msg = std.fmt.allocPrint(self.allocator, "No entry matched '{s}'", .{trimmed_old}) catch "No entry matched";
            return ToolResult.fail(msg);
        }

        const test_entries = try self.allocator.dupe([]const u8, entries.items);
        defer self.allocator.free(test_entries);
        test_entries[match_idx.?] = trimmed_new;

        const new_count = MemoryStore.calcCharCount(test_entries);
        if (new_count > limit) {
            const msg = std.fmt.allocPrint(self.allocator, "Replacement would put memory at {}/{} chars. Shorten the new content or remove other entries first.", .{ new_count, limit }) catch "Memory limit exceeded";
            return ToolResult.fail(msg);
        }

        self.allocator.free(entries.items[match_idx.?]);
        entries.items[match_idx.?] = try self.allocator.dupe(u8, trimmed_new);

        const path = self.getPath(target);
        defer self.allocator.free(path);
        MemoryStore.writeEntries(self.allocator, path, entries.items) catch {};

        return ToolResult{ .success = true, .output = self.formatSuccessResponse(target) };
    }

    pub fn remove(self: *MemoryStore, target: []const u8, old_text: []const u8) !ToolResult {
        const trimmed = std.mem.trim(u8, old_text, " \t\n");
        if (trimmed.len == 0) return ToolResult.fail("old_text cannot be empty");

        const entries = self.getEntries(target);

        var match_idx: ?usize = null;
        for (entries.items, 0..) |entry, i| {
            if (std.mem.indexOf(u8, entry, trimmed) != null) {
                match_idx = i;
                break;
            }
        }

        if (match_idx == null) {
            const msg = std.fmt.allocPrint(self.allocator, "No entry matched '{s}'", .{trimmed}) catch "No entry matched";
            return ToolResult.fail(msg);
        }

        self.allocator.free(entries.items[match_idx.?]);
        for (match_idx.?..entries.items.len - 1) |i| {
            entries.items[i] = entries.items[i + 1];
        }
        _ = entries.pop();

        const path = self.getPath(target);
        defer self.allocator.free(path);
        MemoryStore.writeEntries(self.allocator, path, entries.items) catch {};

        return ToolResult{ .success = true, .output = self.formatSuccessResponse(target) };
    }
};

pub const MemoryTool = struct {
    pub const tool_name = "memory";
    pub const tool_description = "Save durable information to persistent memory that survives across sessions.";
    pub const tool_params = "{\"type\":\"object\",\"properties\":{\"action\":{\"type\":\"string\",\"enum\":[\"add\",\"replace\",\"remove\"]},\"target\":{\"type\":\"string\",\"enum\":[\"memory\",\"user\"]},\"content\":{\"type\":\"string\"},\"old_text\":{\"type\":\"string\"}},\"required\":[\"action\",\"target\"]}";

    store: *MemoryStore,

    pub fn init(allocator: std.mem.Allocator) !MemoryTool {
        const store = try allocator.create(MemoryStore);
        store.* = MemoryStore.init(allocator);
        return MemoryTool{ .store = store };
    }

    pub fn deinit(self: *MemoryTool) void {
        self.store.deinit();
        self.store.allocator.destroy(self.store);
    }

    pub fn tool(self: *MemoryTool) Tool {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    pub fn execute(self: *MemoryTool, allocator: std.mem.Allocator, args: JsonObjectMap) !ToolResult {
        const action = root.getString(args, "action") orelse {
            return ToolResult.fail("action is required");
        };
        const target = root.getString(args, "target") orelse "memory";

        if (!std.mem.eql(u8, target, "memory") and !std.mem.eql(u8, target, "user")) {
            return ToolResult.fail("Invalid target. Use 'memory' or 'user'");
        }

        if (std.mem.eql(u8, action, "add")) {
            const content = root.getString(args, "content") orelse {
                return ToolResult.fail("content is required for 'add' action");
            };
            return self.store.add(target, content);
        } else if (std.mem.eql(u8, action, "replace")) {
            const old_text = root.getString(args, "old_text") orelse {
                return ToolResult.fail("old_text is required for 'replace' action");
            };
            const content = root.getString(args, "content") orelse {
                return ToolResult.fail("content is required for 'replace' action");
            };
            return self.store.replace(target, old_text, content);
        } else if (std.mem.eql(u8, action, "remove")) {
            const old_text = root.getString(args, "old_text") orelse {
                return ToolResult.fail("old_text is required for 'remove' action");
            };
            return self.store.remove(target, old_text);
        }

        const msg = std.fmt.allocPrint(allocator, "Unknown action '{s}'. Use: add, replace, remove", .{action}) catch "Unknown action";
        return ToolResult.fail(msg);
    }

    pub const vtable = root.ToolVTable(@This());
};
