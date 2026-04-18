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
const shared = @import("root.zig").shared;

var g_shutdown_flag = std.atomic.Value(bool).init(false);

fn handleSignal(sig: std.c.SIG) callconv(.c) void {
    _ = sig;
    g_shutdown_flag.store(true, .monotonic);
}

fn setupSignalHandlers() !void {
    var mask: std.c.sigset_t = undefined;
    _ = std.c.sigemptyset(&mask);
    const sa = std.c.Sigaction{
        .handler = .{ .handler = handleSignal },
        .mask = mask,
        .flags = 0,
    };
    _ = std.c.sigaction(std.c.SIG.INT, &sa, null);
    _ = std.c.sigaction(std.c.SIG.TERM, &sa, null);
}

const skill_self_improve = @import("agent/skill_self_improve.zig");
const SkillSelfImprove = skill_self_improve.SkillSelfImprove;

const CliConfig = struct {
    api_key: ?[]const u8,
    db_path: ?[]const u8,
    session_id: []const u8,
    model: []const u8,
    max_iterations: usize,
    provider: providers.Provider,
    server_mode: bool,
    port: u16,
    config_mode: bool,
    enable_skill_self_improve: bool,
};

fn getApiKeyFromEnv(environ: *const std.process.Environ.Map) ?[]const u8 {
    const env_vars = &[_][]const u8{
        "BAILIAN_API_KEY",
        "OPENAI_API_KEY",
        "KIMI_API_KEY",
        "MINIMAX_API_KEY",
        "ZAI_API_KEY",
        "VOLCANO_API_KEY",
        "TENCENT_API_KEY",
    };

    for (env_vars) |var_name| {
        if (environ.get(var_name)) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}

fn parseArgs(args: std.process.Args, environ: *const std.process.Environ.Map) !CliConfig {
    // Start with defaults
    var config = CliConfig{
        .api_key = null,
        .db_path = null,
        .session_id = "default",
        .model = "",
        .max_iterations = 10,
        .provider = .openai,
        .server_mode = false,
        .port = 38789,
        .config_mode = false,
        .enable_skill_self_improve = false,
    };

    // Override with environment variables
    config.api_key = getApiKeyFromEnv(environ);


    // Override with environment variables
    if (config.api_key == null) {
        config.api_key = getApiKeyFromEnv(environ);
    }

    var args_iter = try args.iterateAllocator(std.heap.page_allocator);
    defer args_iter.deinit();

    _ = args_iter.next();

    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try printHelp();
            return error.HelpPrinted;
        } else if (std.mem.eql(u8, arg, "--config") or std.mem.eql(u8, arg, "configure")) {
            config.config_mode = true;
        } else if (std.mem.eql(u8, arg, "--db-path")) {
            config.db_path = args_iter.next() orelse return error.MissingDbPath;
        } else if (std.mem.eql(u8, arg, "--session")) {
            config.session_id = args_iter.next() orelse return error.MissingSession;
        } else if (std.mem.eql(u8, arg, "--model")) {
            config.model = args_iter.next() orelse return error.MissingModel;
        } else if (std.mem.eql(u8, arg, "--max-iterations")) {
            const iter_str = args_iter.next() orelse return error.MissingMaxIterations;
            config.max_iterations = try std.fmt.parseInt(usize, iter_str, 10);
        } else if (std.mem.eql(u8, arg, "--provider")) {
            const provider_str = args_iter.next() orelse return error.MissingProvider;
            config.provider = providers.Provider.fromStr(provider_str) orelse {
                std.log.err("Unknown provider: {s}", .{provider_str});
                std.log.info("Available: openai, kimi, minimax, zai, bailian, volcano, kimi-plan, minimax-plan, bailian-plan, volcano-plan, tencent, tencent-plan", .{});
                return error.InvalidProvider;
            };
            if (config.model.len == 0) {
                config.model = config.provider.defaultModel();
            }
        } else if (std.mem.eql(u8, arg, "--server")) {
            config.server_mode = true;
        } else if (std.mem.eql(u8, arg, "--port")) {
            const port_str = args_iter.next() orelse return error.MissingPort;
            config.port = try std.fmt.parseInt(u16, port_str, 10);
        } else if (std.mem.eql(u8, arg, "--enable-skill-self-improve")) {
            config.enable_skill_self_improve = true;
        }
    }

    if (config.api_key == null) {
        config.api_key = getApiKeyFromEnv(environ);
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
        \\  --config, configure     Run configuration wizard
        \\  --db-path <path>        SQLite database path (default: in-memory)
        \\  --session <id>          Session ID (default: default)
        \\  --model <name>          LLM model name
        \\  --provider <name>       LLM provider: openai, kimi, minimax, zai, bailian, volcano, kimi-plan, minimax-plan, bailian-plan, volcano-plan, tencent, tencent-plan
        \\  --max-iterations <n>    Max ReAct iterations (default: 10)
        \\  --server                Run in HTTP server mode
        \\  --port <port>           Server port (default: 8080)
        \\  --enable-skill-self-improve  Enable skill self-improvement (default: off)
        \\
        \\Environment variables:
        \\  OPENAI_API_KEY, KIMI_API_KEY, MINIMAX_API_KEY,
        \\  ZAI_API_KEY, BAILIAN_API_KEY, VOLCANO_API_KEY, TENCENT_API_KEY
        \\
        \\Examples:
        \\  knot3bot                                    # Interactive mode
        \\  knot3bot --config                         # Configuration wizard
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
    const gpa = shared.context.gpa();
    var arena = std.heap.ArenaAllocator.init(gpa);
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

    var buf: [4096]u8 = undefined;
    var reader = std.Io.File.stdin().reader(shared.context.io(), &buf);
    while (!g_shutdown_flag.load(.monotonic)) {
        std.debug.print("> ", .{});

        const n = reader.interface.readSliceShort(&buf) catch |err| {
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

        // Create SkillSelfImprove engine if enabled
        var si_engine: ?SkillSelfImprove = null;
        if (config.enable_skill_self_improve) {
            si_engine = SkillSelfImprove.init(allocator);
        }
        defer if (si_engine) |*si| si.deinit();

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
            .enable_skill_self_improve = config.enable_skill_self_improve,
            .skill_self_improve = if (si_engine) |*si| si else null,
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

pub fn main(init: std.process.Init) !u8 {
    try setupSignalHandlers();
    shared.context.init(init.io, init.environ_map, init.gpa);

    const config = parseArgs(init.minimal.args, init.environ_map) catch |err| {
        if (err == error.HelpPrinted) return 0;
        return err;
    };

    // Run config mode if requested
    if (config.config_mode) {
        std.debug.print("\n=== knot3bot Configuration ===\n\n", .{});

        const configure_script = "configure.py";

        // Spawn python3 to run configure.py
        var child = std.process.spawn(init.io, .{
            .argv = &[_][]const u8{ "python3", configure_script },
            .stdin = .inherit,
            .stdout = .inherit,
            .stderr = .inherit,
        }) catch |err| {
            std.debug.print("Error: failed to run configure.py: {}\n", .{err});
            return error.ConfigScriptFailed;
        };

        _ = child.wait(init.io) catch |err| {
            std.debug.print("Error: configure.py exited with error: {}\n", .{err});
            return error.ConfigScriptFailed;
        };
        return 0;
    }
    const gpa_state = init.gpa;
    const allocator = gpa_state;
    const workspace_dir = if (init.environ_map.get("HERMES_WORKSPACE")) |v| try allocator.dupe(u8, v) else "/tmp";
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

        const auth_keys = if (config.api_key) |key| &.{key} else &[_][]const u8{};
        const auth_config = AuthConfig{
            .require_auth = false,
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
        try server.start();
        defer {
            server.deinit();
            model_registry.deinit();
        }
    } else {
        try runCliMode(&config, &registry);
    }

    return 0;
}
