const std = @import("std");

/// Configuration structure for knot3bot
/// Supports loading from JSON config files
pub const Config = struct {
    // API settings
    api_key: ?[]const u8 = null,
    api_base: []const u8 = "https://api.openai.com/v1",
    model: []const u8 = "gpt-4",

    // Memory settings
    memory_backend: []const u8 = "memory",
    db_path: []const u8 = "knot3bot.db",

    // Server settings
    server_port: u16 = 8080,
    server_host: []const u8 = "127.0.0.1",

    // Logging settings
    log_level: []const u8 = "info",
    log_file: ?[]const u8 = null,

    // Behavior settings
    max_iterations: u32 = 10,
    timeout_seconds: u32 = 60,

    allocator: ?std.mem.Allocator = null,

    /// Load configuration from a JSON file
    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Config {
        var config = Config{
            .allocator = allocator,
        };

        // Read file contents
        const file = try std.fs.cwd().openFile(path, .{});
        defer file.close();

        const stat = try file.stat();
        const contents = try allocator.alloc(u8, stat.size);
        defer allocator.free(contents);

        _ = try file.readAll(contents);

        // Parse JSON
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, contents, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) {
            return error.InvalidConfigFormat;
        }

        const obj = root.object;

        // Parse API settings
        if (obj.get("api")) |api| {
            if (api == .object) {
                const api_obj = api.object;
                if (api_obj.get("key")) |key| {
                    if (key == .string) {
                        config.api_key = try allocator.dupe(u8, key.string);
                    }
                }
                if (api_obj.get("base")) |base| {
                    if (base == .string) {
                        config.api_base = try allocator.dupe(u8, base.string);
                    }
                }
                if (api_obj.get("model")) |model| {
                    if (model == .string) {
                        config.model = try allocator.dupe(u8, model.string);
                    }
                }
            }
        }

        // Parse memory settings
        if (obj.get("memory")) |memory| {
            if (memory == .object) {
                const mem_obj = memory.object;
                if (mem_obj.get("backend")) |backend| {
                    if (backend == .string) {
                        config.memory_backend = try allocator.dupe(u8, backend.string);
                    }
                }
                if (mem_obj.get("db_path")) |db_path| {
                    if (db_path == .string) {
                        config.db_path = try allocator.dupe(u8, db_path.string);
                    }
                }
            }
        }

        // Parse server settings
        if (obj.get("server")) |server| {
            if (server == .object) {
                const srv_obj = server.object;
                if (srv_obj.get("port")) |port| {
                    if (port == .integer) {
                        config.server_port = @intCast(port.integer);
                    } else if (port == .float) {
                        config.server_port = @intFromFloat(port.float);
                    }
                }
                if (srv_obj.get("host")) |host| {
                    if (host == .string) {
                        config.server_host = try allocator.dupe(u8, host.string);
                    }
                }
            }
        }

        // Parse logging settings
        if (obj.get("logging")) |logging| {
            if (logging == .object) {
                const log_obj = logging.object;
                if (log_obj.get("level")) |level| {
                    if (level == .string) {
                        config.log_level = try allocator.dupe(u8, level.string);
                    }
                }
                if (log_obj.get("file")) |file_path| {
                    if (file_path == .string) {
                        config.log_file = try allocator.dupe(u8, file_path.string);
                    }
                }
            }
        }

        // Parse behavior settings
        if (obj.get("behavior")) |behavior| {
            if (behavior == .object) {
                const beh_obj = behavior.object;
                if (beh_obj.get("max_iterations")) |max_iter| {
                    if (max_iter == .integer) {
                        config.max_iterations = @intCast(max_iter.integer);
                    } else if (max_iter == .float) {
                        config.max_iterations = @intFromFloat(max_iter.float);
                    }
                }
                if (beh_obj.get("timeout_seconds")) |timeout| {
                    if (timeout == .integer) {
                        config.timeout_seconds = @intCast(timeout.integer);
                    } else if (timeout == .float) {
                        config.timeout_seconds = @intFromFloat(timeout.float);
                    }
                }
            }
        }

        return config;
    }

    /// Load configuration from default locations
    /// Tries: 1. KNOT3BOT_CONFIG env var, 2. ~/.knot3bot/config.json, 3. ./knot3bot.json
    pub fn loadDefault(allocator: std.mem.Allocator) !?Config {
        // Try environment variable first
        if (std.process.getEnvVarOwned(allocator, "KNOT3BOT_CONFIG")) |path| {
            defer allocator.free(path);
            return try loadFromFile(allocator, path);
        } else |_| {}

        // Try home directory config
        if (std.process.getEnvVarOwned(allocator, "HOME")) |home| {
            defer allocator.free(home);
            const config_path = try std.fs.path.join(allocator, &.{ home, ".knot3bot", "config.json" });
            defer allocator.free(config_path);
            if (fileExists(config_path)) {
                return try loadFromFile(allocator, config_path);
            }
        } else |_| {}

        // Try current directory
        if (fileExists("knot3bot.json")) {
            return try loadFromFile(allocator, "knot3bot.json");
        }

        return null;
    }

    /// Save configuration to a JSON file
    pub fn saveToFile(self: Config, path: []const u8) !void {
        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var buffer: [4096]u8 = undefined;
        var file_writer = file.writer(&buffer);
        const writer = &file_writer.interface;

        // Write JSON manually for better control
        try std.Io.Writer.writeAll(writer, "{\n");

        // API section
        try std.Io.Writer.writeAll(writer, "  \"api\": {\n");
        if (self.api_key) |key| {
            try std.Io.Writer.print(writer, "    \"key\": \"{s}\",\n", .{key});
        }
        try std.Io.Writer.print(writer, "    \"base\": \"{s}\",\n", .{self.api_base});
        try std.Io.Writer.print(writer, "    \"model\": \"{s}\"\n", .{self.model});
        try std.Io.Writer.writeAll(writer, "  },\n");

        // Memory section
        try std.Io.Writer.writeAll(writer, "  \"memory\": {\n");
        try std.Io.Writer.print(writer, "    \"backend\": \"{s}\",\n", .{self.memory_backend});
        try std.Io.Writer.print(writer, "    \"db_path\": \"{s}\"\n", .{self.db_path});
        try std.Io.Writer.writeAll(writer, "  },\n");

        // Server section
        try std.Io.Writer.writeAll(writer, "  \"server\": {\n");
        try std.Io.Writer.print(writer, "    \"port\": {d},\n", .{self.server_port});
        try std.Io.Writer.print(writer, "    \"host\": \"{s}\"\n", .{self.server_host});
        try std.Io.Writer.writeAll(writer, "  },\n");

        // Logging section
        try std.Io.Writer.writeAll(writer, "  \"logging\": {\n");
        try std.Io.Writer.print(writer, "    \"level\": \"{s}\"", .{self.log_level});
        if (self.log_file) |log_file| {
            try std.Io.Writer.print(writer, ",\n    \"file\": \"{s}\"", .{log_file});
        }
        try std.Io.Writer.writeAll(writer, "\n  },\n");

        // Behavior section
        try std.Io.Writer.writeAll(writer, "  \"behavior\": {\n");
        try std.Io.Writer.print(writer, "    \"max_iterations\": {d},\n", .{self.max_iterations});
        try std.Io.Writer.print(writer, "    \"timeout_seconds\": {d}\n", .{self.timeout_seconds});
        try std.Io.Writer.writeAll(writer, "  }\n");

        try std.Io.Writer.writeAll(writer, "}\n");
        try std.Io.Writer.flush(writer);
    }

    /// Create default config file at the specified path
    pub fn createDefault(allocator: std.mem.Allocator, path: []const u8) !void {
        var config = Config{
            .allocator = allocator,
        };
        try config.saveToFile(path);
    }

    /// Clean up allocated memory
    pub fn deinit(self: *Config) void {
        const allocator = self.allocator orelse return;

        if (self.api_key) |key| {
            allocator.free(key);
        }
        allocator.free(self.api_base);
        allocator.free(self.model);
        allocator.free(self.memory_backend);
        allocator.free(self.db_path);
        allocator.free(self.server_host);
        allocator.free(self.log_level);
        if (self.log_file) |log_file| {
            allocator.free(log_file);
        }
    }
};

fn fileExists(path: []const u8) bool {
    std.fs.cwd().access(path, .{}) catch return false;
    return true;
}

// Tests
test "Config default values" {
    const config = Config{};
    try std.testing.expectEqualStrings("memory", config.memory_backend);
    try std.testing.expectEqualStrings("gpt-4", config.model);
    try std.testing.expectEqual(@as(u16, 8080), config.server_port);
}

test "Config load and save" {
    const allocator = std.testing.allocator;

    // Create a test config
    var config = Config{
        .allocator = allocator,
        .api_key = try allocator.dupe(u8, "test-key"),
        .api_base = try allocator.dupe(u8, "https://api.test.com/v1"),
        .model = try allocator.dupe(u8, "gpt-3.5-turbo"),
        .memory_backend = try allocator.dupe(u8, "sqlite"),
        .db_path = try allocator.dupe(u8, "/tmp/test.db"),
        .server_port = 3000,
        .server_host = try allocator.dupe(u8, "0.0.0.0"),
        .log_level = try allocator.dupe(u8, "debug"),
    };
    defer config.deinit();

    // Save to temp file
    const test_path = "/tmp/knot3bot_test_config.json";
    try config.saveToFile(test_path);

    // Load it back
    var loaded = try Config.loadFromFile(allocator, test_path);
    defer loaded.deinit();

    // Verify values
    try std.testing.expectEqualStrings("test-key", loaded.api_key.?);
    try std.testing.expectEqualStrings("https://api.test.com/v1", loaded.api_base);
    try std.testing.expectEqualStrings("gpt-3.5-turbo", loaded.model);
    try std.testing.expectEqualStrings("sqlite", loaded.memory_backend);
    try std.testing.expectEqualStrings("/tmp/test.db", loaded.db_path);
    try std.testing.expectEqual(@as(u16, 3000), loaded.server_port);
    try std.testing.expectEqualStrings("0.0.0.0", loaded.server_host);
    try std.testing.expectEqualStrings("debug", loaded.log_level);

    // Cleanup
    try std.fs.cwd().deleteFile(test_path);
}
