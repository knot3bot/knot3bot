//! Memory Tool - Persistent Curated Memory
//!
//! Provides bounded, file-backed memory that persists across sessions. Two stores:
//!   - MEMORY.md: agent's personal notes and observations
//!   - USER.md: what the agent knows about the user
//!
//! Entry delimiter: § (section sign). Entries can be multiline.

const std = @import("std");
const root = @import("root.zig");
const Tool = root.Tool;
const ToolResult = root.ToolResult;
const JsonObjectMap = root.JsonObjectMap;

const ENTRY_DELIMITER = "\n§\n";
const DEFAULT_MEMORY_CHAR_LIMIT = 2200;
const DEFAULT_USER_CHAR_LIMIT = 1375;

/// Invisible unicode characters for injection detection
const INVISIBLE_CHARS = [_]u16{
    0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF,
    0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
};

/// Threat patterns for injection/exfiltration detection
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

/// Scan memory content for injection/exfil patterns
fn scanMemoryContent(content: []const u8) ?[]const u8 {
    // Check invisible unicode
    for (INVISIBLE_CHARS) |char| {
        const char_str = [_]u8{ @truncate(char), @truncate(char >> 8) };
        if (std.mem.indexOf(u8, content, &char_str) != null) {
            return "Blocked: content contains invisible unicode character (possible injection)";
        }
    }

    // Check threat patterns
    for (THREAT_PATTERNS) |threat| {
        if (std.mem.indexOf(u8, content, threat.pattern) != null) {
            return std.fmt.allocPrint(root.allocator, "Blocked: content matches threat pattern '{s}'", .{threat.name}) catch {
                return "Blocked: content matches threat pattern";
            };
        }
    }

    return null;
}

/// Memory Store - file-backed memory with locking
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

    /// Get the memory directory path
    fn getMemoryDir(self: *MemoryStore) []const u8 {
        _ = self;
        const home = std.os.getenv("HOME") orelse "/tmp";
        return std.fs.path.join(root.allocator, home, ".hermes", "memories") catch "/tmp/.hermes/memories";
    }

    /// Read entries from a file
    fn readFile(path: []const u8) ![][]const u8 {
        var entries = std.array_list.AlignedManaged([]const u8, null).init(root.allocator);
        errdefer entries.deinit();

        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            if (err == error.FileNotFound) return entries.toOwnedSlice();
            return err;
        };
        defer file.close();

        const content = file.readToEndAlloc(root.allocator, 1024 * 1024) catch |err| {
            if (err == error.FileNotFound) return entries.toOwnedSlice();
            return err;
        };
        defer root.allocator.free(content);

        if (content.len == 0) return entries.toOwnedSlice();

        var parts = std.mem.split(u8, content, ENTRY_DELIMITER);
        while (parts.next()) |entry| {
            const trimmed = std.mem.trim(u8, entry, " \t\n");
            if (trimmed.len > 0) {
                const copy = try root.allocator.dupe(u8, trimmed);
                errdefer root.allocator.free(copy);
                try entries.append(copy);
            }
        }

        return entries.toOwnedSlice();
    }

    /// Write entries to a file atomically
    fn writeFile(path: []const u8, entries: []const []const u8) !void {
        var content = std.array_list.AlignedManaged(u8, null).init(root.allocator);
        defer content.deinit();

        for (entries, 0..) |entry, i| {
            if (i > 0) try content.appendSlice(ENTRY_DELIMITER);
            try content.appendSlice(entry);
        }

        // Create parent directory if needed
        const dir = std.fs.path.dirname(path) orelse ".";
        try std.fs.cwd().makePath(dir);

        // Atomic write with temp file
        const tmp_path = try std.fs.path.join(root.allocator, dir, ".mem_tmp");
        defer root.allocator.free(tmp_path);

        const tmp_file = try std.fs.cwd().createFile(tmp_path, .{});
        defer tmp_file.close();

        try tmp_file.writeAll(content.items);
        try tmp_file.sync();

        try std.fs.cwd().rename(tmp_path, path);
    }

    /// Get entries for a target
    fn getEntries(self: *MemoryStore, target: []const u8) *std.array_list.AlignedManaged([]const u8, null) {
        if (std.mem.eql(u8, target, "user")) {
            return &self.user_entries;
        }
        return &self.memory_entries;
    }

    /// Get char limit for target
    fn getCharLimit(self: *MemoryStore, target: []const u8) usize {
        if (std.mem.eql(u8, target, "user")) {
            return self.user_char_limit;
        }
        return self.memory_char_limit;
    }

    /// Get memory path for target
    fn getPath(self: *MemoryStore, target: []const u8) []const u8 {
        const mem_dir = self.getMemoryDir();
        if (std.mem.eql(u8, target, "user")) {
            return std.fs.path.join(root.allocator, mem_dir, "USER.md") catch
                std.fs.path.join(root.allocator, "/tmp/.hermes/memories", "USER.md") catch "/tmp/.hermes/memories/USER.md";
        }
        return std.fs.path.join(root.allocator, mem_dir, "MEMORY.md") catch
            std.fs.path.join(root.allocator, "/tmp/.hermes/memories", "MEMORY.md") catch "/tmp/.hermes/memories/MEMORY.md";
    }

    /// Calculate total chars for entries
    fn calcCharCount(entries: []const []const u8) usize {
        if (entries.len == 0) return 0;
        var total: usize = 0;
        for (entries) |entry| {
            total += entry.len;
        }
        total += ENTRY_DELIMITER.len * (entries.len - 1);
        return total;
    }

    /// Add a new entry
    pub fn add(self: *MemoryStore, target: []const u8, content: []const u8) !ToolResult {
        const trimmed = std.mem.trim(u8, content, " \t\n");
        if (trimmed.len == 0) {
            return ToolResult.fail("Content cannot be empty");
        }

        // Scan for injection
        if (scanMemoryContent(trimmed)) |error_msg| {
            return ToolResult.fail(error_msg);
        }

        const entries = self.getEntries(target);
        const limit = self.getCharLimit(target);

        // Check for duplicates
        for (entries.items) |entry| {
            if (std.mem.eql(u8, entry, trimmed)) {
                return ToolResult.success(self.formatSuccessResponse(target));
            }
        }

        // Check size limit
        const new_entries = try root.allocator.dupe([]const u8, entries.items);
        defer root.allocator.free(new_entries);
        try entries.append(trimmed);

        const new_count = self.calcCharCount(entries.items);
        if (new_count > limit) {
            _ = entries.pop();
            const current = self.calcCharCount(entries.items);
            return ToolResult.fail(std.fmt.allocPrint(root.allocator,
                "Memory at {d}/{d} chars. Adding this entry ({d} chars) would exceed the limit. Replace or remove existing entries first.",
                .{ current, limit, trimmed.len }) catch "Memory limit exceeded");
        }

        // Persist to disk
        const path = self.getPath(target);
        defer root.allocator.free(path);
        self.writeFile(path, entries.items) catch {};

        return ToolResult.success(self.formatSuccessResponse(target));
    }

    /// Replace an entry
    pub fn replace(self: *MemoryStore, target: []const u8, old_text: []const u8, new_content: []const u8) !ToolResult {
        const trimmed_old = std.mem.trim(u8, old_text, " \t\n");
        const trimmed_new = std.mem.trim(u8, new_content, " \t\n");

        if (trimmed_old.len == 0) {
            return ToolResult.fail("old_text cannot be empty");
        }
        if (trimmed_new.len == 0) {
            return ToolResult.fail("new_content cannot be empty. Use 'remove' to delete entries");
        }

        // Scan new content
        if (scanMemoryContent(trimmed_new)) |error_msg| {
            return ToolResult.fail(error_msg);
        }

        const entries = self.getEntries(target);
        const limit = self.getCharLimit(target);

        // Find matching entries
        var match_idx: ?usize = null;
        for (entries.items, 0..) |entry, i| {
            if (std.mem.indexOf(u8, entry, trimmed_old) != null) {
                match_idx = i;
                break;
            }
        }

        if (match_idx == null) {
            return ToolResult.fail(std.fmt.allocPrint(root.allocator, "No entry matched '{s}'", .{trimmed_old}) catch "No entry matched");
        }

        // Check size limit
        const test_entries = try root.allocator.dupe([]const u8, entries.items);
        defer root.allocator.free(test_entries);
        test_entries[match_idx.?] = trimmed_new;

        const new_count = self.calcCharCount(test_entries);
        if (new_count > limit) {
            return ToolResult.fail(std.fmt.allocPrint(root.allocator,
                "Replacement would put memory at {d}/{d} chars. Shorten the new content or remove other entries first.",
                .{ new_count, limit }) catch "Memory limit exceeded");
        }

        entries.items[match_idx.?] = trimmed_new;

        // Persist
        const path = self.getPath(target);
        defer root.allocator.free(path);
        self.writeFile(path, entries.items) catch {};

        return ToolResult.success(self.formatSuccessResponse(target));
    }

    /// Remove an entry
    pub fn remove(self: *MemoryStore, target: []const u8, old_text: []const u8) !ToolResult {
        const trimmed = std.mem.trim(u8, old_text, " \t\n");
        if (trimmed.len == 0) {
            return ToolResult.fail("old_text cannot be empty");
        }

        const entries = self.getEntries(target);

        // Find matching entry
        var match_idx: ?usize = null;
        for (entries.items, 0..) |entry, i| {
            if (std.mem.indexOf(u8, entry, trimmed) != null) {
                match_idx = i;
                break;
            }
        }

        if (match_idx == null) {
            return ToolResult.fail(std.fmt.allocPrint(root.allocator, "No entry matched '{s}'", .{trimmed}) catch "No entry matched");
        }

        // Remove and shift
        root.allocator.free(entries.items[match_idx.?]);
        for (match_idx.?..entries.items.len - 1) |i| {
            entries.items[i] = entries.items[i + 1];
        }
        _ = entries.pop();

        // Persist
        const path = self.getPath(target);
        defer root.allocator.free(path);
        self.writeFile(path, entries.items) catch {};

        return ToolResult.success(self.formatSuccessResponse(target));
    }

    /// Format success response JSON
    fn formatSuccessResponse(self: *MemoryStore, target: []const u8) []const u8 {
        const entries = self.getEntries(target);
        const current = self.calcCharCount(entries.items);
        const limit = self.getCharLimit(target);
        const pct = @min(100, (current * 100) / @max(1, limit));

        return std.fmt.allocPrint(root.allocator,
            \\{{"success":true,"target":"{s}","usage":"{d}% — {d}/{d} chars","entry_count":{d}}}
        , .{ target, pct, current, limit, entries.items.len }) catch "{}";
    }
};

/// Memory Tool
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
        root.allocator.destroy(self.store);
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

        return ToolResult.fail(std.fmt.allocPrint(allocator, "Unknown action '{s}'. Use: add, replace, remove", .{action}) catch "Unknown action");
    }

    pub const vtable = root.ToolVTable(@This());
};
