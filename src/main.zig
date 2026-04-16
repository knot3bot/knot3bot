const std = @import("std");
const tools = @import("root.zig");
const ToolRegistry = tools.ToolRegistry;
const createDefaultRegistry = tools.createDefaultRegistry;
const Agent = @import("root.zig").Agent;
const createDefaultSystemPrompt = @import("root.zig").createDefaultSystemPrompt;
const providers = @import("root.zig").providers;
const display = @import("display.zig");
const Server = @import("root.zig").Server;
const ServerConfig = @import("root.zig").ServerConfig;
const AuthConfig = @import("root.zig").AuthConfig;
const models = @import("root.zig").models;
const context_compressor = @import("root.zig").context_compressor;
const trajectory = @import("root.zig").trajectory;

var g_shutdown_flag = std.atomic.Value(bool).init(false);

fn handleSignal(sig: c_int) callconv(.c) void {
    _ = sig;
    g_shutdown_flag.store(true, .monotonic);
}

fn setupSignalHandlers() !void {
    const sa = std.posix.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.INT, &sa, null);
    std.posix.sigaction(std.posix.SIG.TERM, &sa, null);
}

const CliConfig = struct {
    api_key: ?[]const u8,
    db_path: ?[]const u8,
    session_id: []const u8,
    model: []const u8,
    max_iterations: usize,
    provider: providers.Provider,
    server_mode: bool,
    port: u16,
};

fn getApiKeyFromEnv() ?[]const u8 {
    const env_vars = &[_][]const u8{
        "BAILIAN_API_KEY",
        "OPENAI_API_KEY",
        "KIMI_API_KEY",
        "MINIMAX_API_KEY",
        "ZAI_API_KEY",
        "VOLCANO_API_KEY",
    };

    for (env_vars) |var_name| {
        if (std.process.getEnvVarOwned(std.heap.page_allocator, var_name)) |value| {
            return value;
        } else |_| {
            continue;
        }
    }
    return null;
}

fn parseArgs() !CliConfig {
    var config = CliConfig{
        .api_key = null,
        .db_path = null,
        .session_id = "default",
        .model = "",
        .max_iterations = 10,
        .provider = .openai,
        .server_mode = false,
        .port = 8080,
    };

    var args = try std.process.argsWithAllocator(std.heap.page_allocator);
    defer args.deinit();

    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--db-path")) {
            config.db_path = args.next() orelse return error.MissingDbPath;
        } else if (std.mem.eql(u8, arg, "--session")) {
            config.session_id = args.next() orelse return error.MissingSession;
        } else if (std.mem.eql(u8, arg, "--model")) {
            config.model = args.next() orelse return error.MissingModel;
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            const iter_str = args.next() orelse return error.MissingMaxIterations;
            config.max_iterations = try std.fmt.parseInt(usize, iter_str, 10);
        } else if (std.mem.eql(u8, arg, "--provider")) {
            const provider_str = args.next() orelse return error.MissingProvider;
            config.provider = providers.Provider.fromStr(provider_str) orelse {
                std.log.err("Unknown provider: {s}", .{provider_str});
                std.log.info("Available: openai, kimi, minimax, zai, bailian, volcano", .{});
                return error.InvalidProvider;
            };
            if (config.model.len == 0) {
                config.model = config.provider.defaultModel();
            }
        } else if (std.mem.eql(u8, arg, "--server")) {
            config.server_mode = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = args.next() orelse return error.MissingPort;
            config.port = try std.fmt.parseInt(u16, port_str, 10);
        }
    }

    if (config.api_key == null) {
        config.api_key = getApiKeyFromEnv();
    }

    return config;
}

fn printHelp() !void {
    std.debug.print(
        \\knot3bot - AI Agent in Zig
        \\
        \\Usage: knot3bot [options]
        \\
        \\Options:
        \\  --help, -h              Show this help message
        \\  --db-path <path>        SQLite database path (default: in-memory)
        \\  --session <id>          Session ID (default: default)
        \\  --model <name>          LLM model name
        \\  --provider <name>       LLM provider: openai, kimi, minimax, zai, bailian, volcano
        \\  --max-iterations <n>    Max ReAct iterations (default: 10)
        \\  --server                Run in HTTP server mode
        \\  --port <port>           Server port (default: 8080)
        \\
        \\Environment variables:
        \\  OPENAI_API_KEY, KIMI_API_KEY, MINIMAX_API_KEY,
        \\  ZAI_API_KEY, BAILIAN_API_KEY, VOLCANO_API_KEY
        \\
        \\Examples:
        \\  knot3bot                                    # Interactive mode
        \\  BAILIAN_API_KEY=xxx knot3bot --provider bailian
        \\  knot3bot --db-path ./memory.db --session dev
        \\  knot3bot --server --port 8080
        \\
    , .{});
}

fn printSessionInfo(config: *const CliConfig, memory_path: []const u8) void {
    var disp = display.Display.init(std.heap.page_allocator);
    disp.printHeader("knot3bot v0.0.1");
    std.debug.print("Session: {s} | Memory: {s} | Provider: {s} | Model: {s}\n", .{
        config.session_id,
        memory_path,
        config.provider.name(),
        config.model,
    });
    std.debug.print("Commands: exit/quit, clear, sessions\n\n", .{});
}

const MemoryManager = @import("memory/root.zig").MemoryManager;
const ManagerMemoryBackend = @import("memory/root.zig").ManagerMemoryBackend;
const MemorySystem = @import("memory/root.zig").MemorySystem;
const SqliteMemorySystem = @import("memory/root.zig").SqliteMemorySystem;

fn runCliMode(config: *const CliConfig, registry: *const ToolRegistry) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const allocator = arena.allocator();

    var in_memory = MemorySystem.init(allocator);
    var sqlite: ?*SqliteMemorySystem = null;
    if (config.db_path) |p| {
        sqlite = try allocator.create(SqliteMemorySystem);
        sqlite.?.* = try SqliteMemorySystem.init(allocator, p);
    }

    const backends = try allocator.alloc(ManagerMemoryBackend, if (sqlite != null) 2 else 1);
    backends[0] = .{ .memory = &in_memory };
    if (sqlite) |s| backends[1] = .{ .sqlite = s };

    var manager = MemoryManager.init(allocator, backends);
    defer manager.deinit();
    defer in_memory.deinit();
    defer if (sqlite) |s| {
        s.deinit();
        allocator.destroy(s);
    };

    try manager.createSession(config.session_id);

    const memory_path = if (config.db_path) |p| p else "in-memory";
    printSessionInfo(config, memory_path);

    const stdin_file = std.fs.File.stdin();
    var buf: [4096]u8 = undefined;

    while (!g_shutdown_flag.load(.monotonic)) {
        std.debug.print("{s}> {s}", .{ display.Colors.blue, display.Colors.reset });
        std.debug.print("> ", .{});

        const n = stdin_file.read(&buf) catch |err| {
            std.debug.print("Read error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (n == 0) break;

        const input = buf[0..n];
        const trimmed = std.mem.trim(u8, input, " \n\r");

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            std.debug.print("Goodbye!\n", .{});
            break;
        }

        if (std.mem.eql(u8, trimmed, "clear")) {
            manager.deleteSession(config.session_id);
            manager.createSession(config.session_id) catch {};
            std.debug.print("Session cleared.\n\n", .{});
            continue;
        }

        if (std.mem.eql(u8, trimmed, "sessions")) {
            const sessions = manager.listSessions(allocator) catch |err| {
                std.debug.print("Error listing sessions: {s}\n\n", .{@errorName(err)});
                continue;
            };
            defer {
                for (sessions) |s| allocator.free(s);
            }
            std.debug.print("Sessions: {d}\n", .{sessions.len});
            for (sessions) |s| {
                std.debug.print("  - {s}\n", .{s});
            }
            std.debug.print("\n", .{});
            continue;
        }

        if (trimmed.len == 0) continue;

        std.debug.print("\n", .{});
        try runAgentStream(allocator, config, registry, &manager, trimmed);
        std.debug.print("\n\n", .{});
    }
}

fn runAgentStream(allocator: std.mem.Allocator, config: *const CliConfig, registry: *const ToolRegistry, memory: *MemoryManager, user_input: []const u8) !void {
    const system_prompt = try createDefaultSystemPrompt(allocator, registry);

    if (config.api_key) |api_key| {
        var model_registry = try models.createDefaultModelRegistry(allocator);
        defer model_registry.deinit();

        var recorder = trajectory.TrajectoryRecorder.init(allocator);

        var compressor = context_compressor.ContextCompressor.init(
            allocator,
            config.model,
            config.provider,
            api_key,
            null,
        );
        defer compressor.deinit();

        const agent_config = Agent.AgentConfig{
            .max_iterations = @intCast(config.max_iterations),
            .model = config.model,
            .api_key = api_key,
            .provider = config.provider,
            .system_prompt = system_prompt,
            .context_compressor = compressor,
            .enable_trajectory_recording = true,
            .trajectory_recorder = &recorder,
            .model_registry = &model_registry,
            .enable_smart_routing = true,
        };

        var agent = Agent.Agent.init(allocator, agent_config, registry);
        defer agent.deinit();

        std.debug.print("[Agent running...\n\n", .{});
        const response = agent.run(user_input) catch |err| {
            std.debug.print("{s}Agent error: {s}\n", .{ display.Colors.red, @errorName(err) });
            return;
        };
        defer allocator.free(response);

        std.debug.print("\n{s}Final Answer:{s}\n{s}\n", .{ display.Colors.green, display.Colors.reset, response });

        try memory.addMessage(config.session_id, "assistant", response);

        const stats = agent.getUsageStats();
        std.debug.print("{s}Iterations: {d} | Tool calls: {d} | API calls: {d}{s}\n", .{ display.Colors.dim, stats.iterations, stats.tool_calls, stats.api_calls, display.Colors.reset });
    } else {
        std.debug.print("[ERROR] No API key configured. Set OPENAI_API_KEY or other provider key.\n", .{});
    }
}

pub fn main() !void {
    try setupSignalHandlers();

    const config = try parseArgs();

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const workspace_dir = std.process.getEnvVarOwned(allocator, "HERMES_WORKSPACE") catch "/tmp";
    defer if (workspace_dir.len > 0 and !std.mem.eql(u8, workspace_dir, "/tmp")) allocator.free(workspace_dir);

    var registry = try createDefaultRegistry(allocator, workspace_dir);
    defer registry.deinit();

    std.log.info("knot3bot v0.0.1 starting...", .{});
    std.log.info("Provider: {s} | Model: {s} | Memory: {s} | Tools: {d}", .{
        config.provider.name(),
        config.model,
        if (config.db_path) |p| p else "in-memory",
        registry.count(),
    });

    if (config.server_mode) {
        const agent_config = Agent.AgentConfig{
            .max_iterations = @intCast(config.max_iterations),
            .model = config.model,
            .api_key = config.api_key,
            .provider = config.provider,
        };

        const auth_keys = if (config.api_key) |key| &.{key} else &.{};
        const auth_config = AuthConfig{
            .require_auth = config.api_key != null,
            .api_keys = auth_keys,
            .allowed_origins = &.{},
        };

        var server = try Server.init(
            allocator,
            agent_config,
            &registry,
            config.port,
            &g_shutdown_flag,
            config.db_path,
            auth_config,
            ServerConfig{},
        );

        // Setup advanced features for server mode
        if (config.api_key) |api_key| {
            server.context_compressor = context_compressor.ContextCompressor.init(
                allocator,
                config.model,
                config.provider,
                api_key,
                null,
            );
            server.trajectory_recorder = trajectory.TrajectoryRecorder.init(allocator);
        }
        var model_registry = try models.createDefaultModelRegistry(allocator);
        server.model_registry = &model_registry;
        defer {
            server.deinit();
            model_registry.deinit();
        }
    } else {
        try runCliMode(&config, &registry);
    }
}
