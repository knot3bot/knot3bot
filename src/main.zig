const std = @import("std");
const tools = @import("root.zig");
const ToolRegistry = tools.ToolRegistry;
const createDefaultRegistry = tools.createDefaultRegistry;
const createFullRegistry = tools.createFullRegistry;
const Agent = @import("root.zig").Agent;
const createDefaultSystemPrompt = @import("root.zig").createDefaultSystemPrompt;
const providers = @import("root.zig").providers;
const display = @import("display.zig");
const cli = @import("cli.zig");
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

fn handleSigpipe(_: std.c.SIG) callconv(.c) void {
    // Ignore SIGPIPE — writing to a broken pipe is handled via error returns.
    // We must not set g_shutdown_flag here because SIGPIPE is a normal event
    // during streaming when clients disconnect.
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

    const sa_pipe = std.c.Sigaction{
        .handler = .{ .handler = handleSigpipe },
        .mask = mask,
        .flags = 0,
    };
    _ = std.c.sigaction(std.c.SIG.PIPE, &sa_pipe, null);
}

const skill_self_improve = @import("agent/skill_self_improve.zig");
const skills = @import("agent/skills.zig");
const credential_pool = @import("agent/credential_pool.zig");
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

fn validateApiKeyFormat(key: []const u8, provider: providers.Provider) void {
    const prefix: ?[]const u8 = switch (provider) {
        .openai => "sk-",
        .anthropic => "sk-ant-",
        .bailian, .bailian_plan => "sk-",
        else => null,
    };
    if (prefix) |p| {
        if (!std.mem.startsWith(u8, key, p)) {
            std.log.warn("API key for {s} doesn't match expected format. Keys should start with: {s}", .{
                provider.name(), p,
            });
        }
    }
    if (key.len < 16) {
        std.log.warn("API key for {s} is suspiciously short ({d} chars)", .{ provider.name(), key.len });
    }
}

fn getApiKeyFromEnv(environ: *const std.process.Environ.Map) ?[]const u8 {
    const env_vars = &[_][]const u8{
        "BAILIAN_API_KEY", "OPENAI_API_KEY", "DEEPSEEK_API_KEY",
        "KIMI_API_KEY", "MINIMAX_API_KEY", "ZAI_API_KEY",
        "VOLCANO_API_KEY", "OPENROUTER_API_KEY", "TENCENT_API_KEY",
        "ANTHROPIC_API_KEY",
    };

    for (env_vars) |var_name| {
        if (environ.get(var_name)) |value| {
            if (value.len > 0) return value;
        }
    }
    return null;
}

/// Collect all API keys for the given provider from environment variables.
/// Checks PRIMARY_KEY, PRIMARY_KEY_2, PRIMARY_KEY_3, etc.
fn collectKeysForProvider(allocator: std.mem.Allocator, environ: *const std.process.Environ.Map, provider: providers.Provider) [][]const u8 {
    const base_var = switch (provider) {
        .openai => "OPENAI_API_KEY",
        .deepseek => "DEEPSEEK_API_KEY",
        .kimi, .kimi_plan => "KIMI_API_KEY",
        .minimax, .minimax_plan => "MINIMAX_API_KEY",
        .bailian, .bailian_plan => "BAILIAN_API_KEY",
        .volcano, .volcano_plan => "VOLCANO_API_KEY",
        .zai => "ZAI_API_KEY",
        .openrouter => "OPENROUTER_API_KEY",
        .tencent, .tencent_plan => "TENCENT_API_KEY",
        .anthropic => "ANTHROPIC_API_KEY",
    };

    var keys = std.ArrayList([]const u8).initCapacity(allocator, 4) catch return &.{};
    // Check primary key
    if (environ.get(base_var)) |v| {
        if (v.len > 0) keys.append(allocator, v) catch {};
    }
    // Check numbered suffixes: _2, _3, _4
    var buf: [64]u8 = undefined;
    for (2..6) |n| {
        const suffix = std.fmt.bufPrint(&buf, "{s}_{d}", .{ base_var, n }) catch break;
        if (environ.get(suffix)) |v| {
            if (v.len > 0) keys.append(allocator, v) catch break;
        } else break;
    }
    return keys.toOwnedSlice(allocator) catch &.{};
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
        \\  --provider <name>       LLM provider: openai, deepseek, kimi, minimax, zai, bailian, volcano, openrouter, tencent (+ -plan variants)
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

fn sessionPrompt(config: *const CliConfig) []const u8 {
    _ = config;
    return "> ";
}

fn printSessionInfo(config: *const CliConfig, memory_path: []const u8) void {
    var disp = display.Display.init(std.heap.page_allocator);
    disp.printHeader("knot3bot v0.1.0");
    const model_display: []const u8 = if (config.model.len > 0) config.model else "(not set)";
    std.debug.print("\n", .{});
    std.debug.print("  {s}Provider:{s} {s}    {s}Model:{s} {s}    {s}Session:{s} {s}\n", .{
        display.Colors.dim, display.Colors.reset, config.provider.name(),
        display.Colors.dim, display.Colors.reset, model_display,
        display.Colors.dim, display.Colors.reset, config.session_id,
    });
    std.debug.print("  {s}Memory:{s}  {s}    {s}Tools:{s} 16 loaded\n", .{
        display.Colors.dim, display.Colors.reset, memory_path,
        display.Colors.dim, display.Colors.reset,
    });
    if (config.api_key == null) {
        std.debug.print("\n  {s}Warning:{s} No API key configured.\n", .{ display.Colors.yellow, display.Colors.reset });
    }
    std.debug.print("\n{s}Type /help for commands{s}\n\n", .{ display.Colors.dim, display.Colors.reset });
}

const MemoryManager = @import("memory/root.zig").MemoryManager;
const ManagerMemoryBackend = @import("memory/root.zig").ManagerMemoryBackend;
const MemorySystem = @import("memory/root.zig").MemorySystem;
const SqliteMemorySystem = @import("memory/root.zig").SqliteMemorySystem;

fn runCliMode(config: *CliConfig, registry: *ToolRegistry) !void {
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

    while (!g_shutdown_flag.load(.monotonic)) {
        const prompt = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}{s} {s}>{s} ", .{
            display.Colors.bold, display.Colors.blue,
            if (config.model.len > 0) config.model else "?",
            display.Colors.dim,
            display.Colors.reset,
            display.Colors.blue, display.Colors.reset,
        });
        defer allocator.free(prompt);
        const line = cli.readLine(prompt) catch |err| {
            std.debug.print("Read error: {s}\n", .{@errorName(err)});
            continue;
        };
        if (line == null) break; // Ctrl-C or Ctrl-D
        defer std.heap.page_allocator.free(line.?);
        const trimmed = std.mem.trim(u8, line.?, " \n\r");
        if (trimmed.len == 0) continue;

        // Handle slash commands
        if (trimmed[0] == '/') {
            // Slash discovery: if no space in input (incomplete command), show suggestions
            if (std.mem.indexOfScalar(u8, trimmed, ' ') == null and trimmed.len > 1) {
                const known = [_][]const u8{ "help", "quit", "exit", "q", "new", "clear", "config", "model", "tools", "skills", "setup", "h" };
                var is_known = false;
                for (&known) |k| {
                    if (std.mem.eql(u8, trimmed[1..], k)) { is_known = true; break; }
                }
                if (!is_known) {
                    cli.discoverCommands(trimmed);
                    continue;
                }
            }

            var action = cli.parseCommand(allocator, trimmed);
            defer cli.deinitAction(&action, allocator);
            switch (action) {
                .quit => {
                    std.debug.print("Goodbye!\n", .{});
                    break;
                },
                .new_session => {
                    manager.deleteSession(config.session_id);
                    manager.createSession(config.session_id) catch {};
                    std.debug.print("\n{s}New session started.{s}\n\n", .{ display.Colors.green, display.Colors.reset });
                },
                .show_help => cli.printHelp(),
                .show_config => {
                    // Try interactive setup wizard if no model set
                    if (config.model.len == 0 or config.api_key == null) {
                        try runSetupWizard(config);
                    } else {
                        cli.printConfig(.{
                            .allocator = allocator,
                            .model = config.model,
                            .provider = config.provider,
                            .api_key = config.api_key,
                            .tool_names = &.{},
                            .skill_names = &.{},
                            .active_skill = null,
                            .session_id = config.session_id,
                        });
                    }
                },
                .show_models => {
                    if (cli.supportsInteractive()) {
                        const models_list = config.provider.models();
                        if (interactiveSelect(allocator, "Select Model", models_list)) |idx| {
                            if (idx < models_list.len) {
                                const old_model = config.model;
                                config.model = models_list[idx];
                                std.debug.print("{s}Model: {s} → {s}{s}\n", .{ display.Colors.green, old_model, config.model, display.Colors.reset });
                            }
                        }
                    } else {
                        cli.printModels(config.provider);
                        std.debug.print("Use {s}/model <name>{s} to switch\n\n", .{ display.Colors.cyan, display.Colors.reset });
                    }
                },
                .switch_model => |model| {
                    config.model = model;
                    std.debug.print("{s}Model switched to:{s} {s}\n", .{ display.Colors.green, display.Colors.reset, model });
                },
                .show_tools => {
                    const entries = registry.list();
                    var names: std.ArrayList([]const u8) = .empty;
                    defer names.deinit(allocator);
                    for (entries) |e| names.append(allocator, e.spec.name) catch continue;
                    if (cli.supportsInteractive()) {
                        if (interactiveSelect(allocator, "Tools (toggle: auto via /tools enable/disable)", names.items)) |_| {
                            std.debug.print("{s}Use /tools enable <name> or /tools disable <name>{s}\n", .{ display.Colors.cyan, display.Colors.reset });
                        }
                    } else cli.printTools(names.items);
                },
                .show_skills => cli.printSkills(&.{}, null),
                .toggle_tool => |tt| {
                    std.debug.print("{s}Tool '{s}' {s}.{s}\n", .{
                        display.Colors.green, tt.name,
                        if (tt.enable) "enabled" else "disabled",
                        display.Colors.reset,
                    });
                },
                .view_skill => |name| {
                    if (cli.supportsInteractive()) {
                        const skill_title = try std.fmt.allocPrint(allocator, "Skill: {s}", .{name});
                        defer allocator.free(skill_title);
                        _ = cli.interactiveMenu(allocator, skill_title, &.{ "[View]", "[Use]", "[Cancel]" }) catch null;
                    }
                    std.debug.print("{s}Skill:{s} {s}\n", .{ display.Colors.cyan, display.Colors.reset, name });
                },
                .use_skill => |name| {
                    std.debug.print("{s}Activated skill:{s} {s}\n", .{ display.Colors.green, display.Colors.reset, name });
                },
                .clear_skill => {
                    std.debug.print("{s}Skill cleared.{s}\n", .{ display.Colors.green, display.Colors.reset });
                },
                .send_message => |msg| {
                    std.debug.print("\n", .{});
                    try runAgentStream(allocator, config, registry, &manager, msg);
                    std.debug.print("\n\n", .{});
                },
                .none => {
                    std.debug.print("{s}Unknown command:{s} {s}\n", .{ display.Colors.red, display.Colors.reset, trimmed });
                    std.debug.print("Type {s}/help{s} for available commands.\n", .{ display.Colors.cyan, display.Colors.reset });
                },
            }
            continue;
        }

        // Handle legacy commands for backward compatibility
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

        // Regular message — send to agent
        std.debug.print("\n", .{});
        try runAgentStream(allocator, config, registry, &manager, trimmed);
        std.debug.print("\n\n", .{});
    }
}

/// Run an interactive selection menu, returning the chosen index or null.
fn interactiveSelect(allocator: std.mem.Allocator, title: []const u8, items: []const []const u8) ?usize {
    return cli.interactiveMenu(allocator, title, items) catch null;
}

/// Interactive setup wizard — provider → API key → model
fn runSetupWizard(config: *CliConfig) !void {
    var d = display.Display.init(std.heap.page_allocator);
    d.printHeader("Setup Wizard");
    std.debug.print("\n", .{});

    // Step 1: Select provider
    const provider_names = [_][]const u8{ "OpenAI", "DeepSeek", "Kimi (Moonshot)", "Bailian (Alibaba)", "MiniMax", "Z.ai (Zhipu)", "OpenRouter", "Volcano Engine", "Tencent (Hunyuan)", "Anthropic" };
    const provider_values = [_]providers.Provider{ .openai, .deepseek, .kimi, .bailian, .minimax, .zai, .openrouter, .volcano, .tencent, .anthropic };
    std.debug.print("Step 1: Select Provider\n", .{});
    if (cli.supportsInteractive()) {
        if (interactiveSelect(std.heap.page_allocator, "Choose Provider", &provider_names)) |idx| {
            if (idx < provider_values.len) {
                config.provider = provider_values[idx];
                std.debug.print("{s}Provider: {s}{s}\n", .{ display.Colors.green, config.provider.name(), display.Colors.reset });
            }
        }
    } else {
        std.debug.print("Available providers:\n", .{});
        for (&provider_names, 0..) |name, i| {
            std.debug.print("  {d}. {s}\n", .{ i + 1, name });
        }
        std.debug.print("Use {s}--provider <name>{s} flag to set.\n\n", .{ display.Colors.cyan, display.Colors.reset });
    }

    // Step 2: API key hint
    std.debug.print("\nStep 2: Set API Key\n", .{});
    const env_var = switch (config.provider) {
        .openai => "OPENAI_API_KEY",
        .deepseek => "DEEPSEEK_API_KEY",
        .kimi, .kimi_plan => "KIMI_API_KEY",
        .minimax, .minimax_plan => "MINIMAX_API_KEY",
        .bailian, .bailian_plan => "BAILIAN_API_KEY",
        .volcano, .volcano_plan => "VOLCANO_API_KEY",
        .zai => "ZAI_API_KEY",
        .openrouter => "OPENROUTER_API_KEY",
        .tencent, .tencent_plan => "TENCENT_API_KEY",
        .anthropic => "ANTHROPIC_API_KEY",
    };
    if (config.api_key != null) {
        std.debug.print("  {s}API key configured.{s}\n", .{ display.Colors.green, display.Colors.reset });
    } else {
        std.debug.print("  Set the {s}{s}{s} environment variable.\n", .{ display.Colors.cyan, env_var, display.Colors.reset });
        std.debug.print("  Or run: {s}export {s}=your-key-here{s}\n", .{ display.Colors.dim, env_var, display.Colors.reset });
    }

    // Step 3: Select model
    std.debug.print("\nStep 3: Select Model\n", .{});
    const models_list = config.provider.models();
    if (cli.supportsInteractive()) {
        if (interactiveSelect(std.heap.page_allocator, "Choose Model", models_list)) |idx| {
            if (idx < models_list.len) {
                config.model = models_list[idx];
                std.debug.print("{s}Model: {s}{s}\n", .{ display.Colors.green, config.model, display.Colors.reset });
            }
        }
    } else {
        for (models_list, 0..) |m, i| {
            std.debug.print("  {d}. {s}\n", .{ i + 1, m });
        }
        std.debug.print("Use {s}/model <name>{s} to switch.\n", .{ display.Colors.cyan, display.Colors.reset });
    }

    std.debug.print("\n{s}Setup complete!{s} Type /help for commands.\n\n", .{ display.Colors.green, display.Colors.reset });
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

        // Initialize credential pool for multi-key rotation
        var cp = credential_pool.CredentialPool.init(
            allocator,
            collectKeysForProvider(allocator, shared.context.environ(), config.provider),
        );

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
            .credential_pool = if (cp.keys.len > 0) &cp else null,
        };

        var agent = Agent.Agent.init(allocator, agent_config, registry);
        defer agent.deinit();

        // Load conversation history from memory
        if (memory.getHistoryJSON(allocator, config.session_id)) |history| {
            if (history) |h| {
                agent.loadHistoryFromJSON(h) catch {};
            }
        } else |_| {}

        // Load default skills
        var skill_registry = skills.createDefaultSkills(allocator) catch null;
        if (skill_registry) |*sr| {
            agent.setSkillRegistry(sr);
        }

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

    var config = parseArgs(init.minimal.args, init.environ_map) catch |err| {
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

    // Validate API key format
    if (config.api_key) |key| {
        validateApiKeyFormat(key, config.provider);
    } else {
        if (!config.config_mode) {
            std.log.warn("No API key configured. Set *_API_KEY env var or use --config wizard.", .{});
        }
    }

    if (config.server_mode) {
        const agent_config = Agent.AgentConfig{
            .max_iterations = @intCast(config.max_iterations),
            .model = config.model,
            .api_key = config.api_key,
            .provider = config.provider,
        };

        const auth_keys = if (config.api_key) |key| &.{key} else &[_][]const u8{};
        const auth_config = AuthConfig{
            .require_auth = auth_keys.len > 0,
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
            ServerConfig{
                .enable_skill_self_improve = config.enable_skill_self_improve,
            },
        );

        // Initialize credential pool for server mode
        server.credential_pool = credential_pool.CredentialPool.init(
            allocator,
            collectKeysForProvider(allocator, shared.context.environ(), config.provider),
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
            server.enable_skill_self_improve = config.enable_skill_self_improve;
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
