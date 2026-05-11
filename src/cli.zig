//! Interactive CLI with slash commands and terminal menus.
//!
//! Provides:
//! - Slash commands: /help, /quit, /new, /config, /model, /tools, /skills
//! - Slash discovery: type / to see available commands
//! - Interactive menus: arrow-key navigation for model/tool/skills selection
//! - Falls back to line-mode when terminal doesn't support raw input

const std = @import("std");
const display = @import("display.zig");
const root = @import("root.zig");
const Provider = root.providers.Provider;

pub const CliAction = union(enum) {
    quit,
    new_session,
    send_message: []const u8,
    switch_model: []const u8,
    toggle_tool: struct { name: []const u8, enable: bool },
    view_skill: []const u8,
    use_skill: []const u8,
    clear_skill,
    show_help,
    show_config,
    show_models,
    show_tools,
    show_skills,
    none,
};

/// Command context for dispatching
pub const CommandContext = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    provider: Provider,
    api_key: ?[]const u8,
    tool_names: []const []const u8,
    skill_names: []const []const u8,
    active_skill: ?[]const u8,
    session_id: []const u8,
};

/// Free any allocated strings in a CliAction.
pub fn deinitAction(action: *CliAction, allocator: std.mem.Allocator) void {
    switch (action.*) {
        .switch_model => |m| allocator.free(m),
        .toggle_tool => |tt| allocator.free(tt.name),
        .view_skill => |s| allocator.free(s),
        .use_skill => |s| allocator.free(s),
        .send_message => |m| allocator.free(m),
        else => {},
    }
    action.* = .none;
}

/// Parse a slash command from user input.
/// Returns the action to take. Caller must call deinitAction to free strings.
pub fn parseCommand(allocator: std.mem.Allocator, input: []const u8) CliAction {
    const trimmed = std.mem.trim(u8, input, " \n\r");
    if (trimmed.len == 0 or trimmed[0] != '/') return .none;

    const rest = trimmed[1..];
    // Split on first whitespace (space, tab, newline) to get the command
    const space_idx = std.mem.indexOfAny(u8, rest, " \t\n\r") orelse rest.len;
    const cmd = rest[0..space_idx];
    const args = if (space_idx < rest.len) std.mem.trim(u8, rest[space_idx + 1 ..], " \t\n\r") else "";

    if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "exit") or std.mem.eql(u8, cmd, "q")) {
        return .quit;
    } else if (std.mem.eql(u8, cmd, "new") or std.mem.eql(u8, cmd, "clear")) {
        return .new_session;
    } else if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h")) {
        return .show_help;
    } else if (std.mem.eql(u8, cmd, "config")) {
        return .show_config;
    } else if (std.mem.eql(u8, cmd, "provider")) {
        return .show_config; // opens setup/config with provider focus
    } else if (std.mem.eql(u8, cmd, "setup")) {
        return .show_config; // opens setup wizard
    } else if (std.mem.eql(u8, cmd, "model")) {
        if (args.len > 0) {
            return .{ .switch_model = allocator.dupe(u8, args) catch return .none };
        }
        return .show_models;
    } else if (std.mem.eql(u8, cmd, "tools")) {
        if (std.mem.eql(u8, args, "list") or args.len == 0) {
            return .show_tools;
        } else if (std.mem.startsWith(u8, args, "enable ")) {
            const name = args["enable ".len..];
            return .{ .toggle_tool = .{ .name = allocator.dupe(u8, name) catch return .none, .enable = true } };
        } else if (std.mem.startsWith(u8, args, "disable ")) {
            const name = args["disable ".len..];
            return .{ .toggle_tool = .{ .name = allocator.dupe(u8, name) catch return .none, .enable = false } };
        }
        return .show_tools;
    } else if (std.mem.eql(u8, cmd, "skills")) {
        if (std.mem.eql(u8, args, "clear")) {
            return .clear_skill;
        } else if (std.mem.startsWith(u8, args, "view ")) {
            const name = args["view ".len..];
            return .{ .view_skill = allocator.dupe(u8, name) catch return .none };
        } else if (std.mem.startsWith(u8, args, "use ")) {
            const name = args["use ".len..];
            return .{ .use_skill = allocator.dupe(u8, name) catch return .none };
        } else if (args.len == 0) {
            return .show_skills;
        }
        return .show_skills;
    } else if (std.mem.eql(u8, cmd, "setup")) {
        return .show_config;
    }
    // Unknown command — treat as message
    return .none;
}

/// Get available slash commands for discovery
pub fn getCommands() []const []const u8 {
    return &.{
        "/setup", "/model", "/config", "/tools", "/skills",
        "/skills view <name>", "/skills use <name>", "/skills clear",
        "/new", "/help", "/quit",
    };
}

/// Show commands matching a partial slash input.
/// Called when user types / followed by incomplete text.
pub fn discoverCommands(partial: []const u8) void {
    const trimmed = std.mem.trim(u8, partial, " /\n\r");
    const all_cmds = getCommands();

    std.debug.print("\n", .{});
    var matched: usize = 0;
    for (all_cmds) |cmd| {
        if (trimmed.len == 0 or std.mem.startsWith(u8, cmd, partial) or std.mem.indexOf(u8, cmd, trimmed) != null) {
            std.debug.print("  {s}{s}{s}\n", .{ display.Colors.cyan, cmd, display.Colors.reset });
            matched += 1;
        }
    }
    if (matched > 0) {
        std.debug.print("\n{s}↑ Use Tab to complete, type more to filter{s}\n", .{ display.Colors.dim, display.Colors.reset });
    }
}

/// Print help for all slash commands
pub fn printHelp() void {
    var d = display.Display.init(std.heap.page_allocator);
    d.printHeader("knot3bot Commands");
    std.debug.print("\n", .{});
    printCmd("/setup", "Re-run setup wizard");
    printCmd("/model [name]", "Switch to model or show available models");
    printCmd("/config", "Show current configuration");
    printCmd("/tools", "Show tool state or toggle tools");
    printCmd("/tools enable <name>", "Enable a tool");
    printCmd("/tools disable <name>", "Disable a tool");
    printCmd("/skills", "Show installed skills");
    printCmd("/skills view <name>", "View a skill");
    printCmd("/skills use <name>", "Activate a skill for this session");
    printCmd("/skills clear", "Clear the active skill");
    printCmd("/new", "Start a new conversation");
    printCmd("/help", "Show this help");
    printCmd("/quit", "Exit");
    std.debug.print("\n", .{});
    std.debug.print("Type / to discover commands (terminal permitting).\n", .{});
    std.debug.print("Anything else is sent to the agent.\n\n", .{});
}

fn printCmd(cmd: []const u8, desc: []const u8) void {
    std.debug.print("  {s}{s}{s}  {s}{s}{s}\n", .{
        display.Colors.cyan, cmd, display.Colors.reset,
        display.Colors.dim,   desc, display.Colors.reset,
    });
}

/// Print current configuration
pub fn printConfig(ctx: CommandContext) void {
    var d = display.Display.init(std.heap.page_allocator);
    d.printHeader("Configuration");
    std.debug.print("\n", .{});
    std.debug.print("  {s}Model:{s}        {s}\n", .{ display.Colors.dim, display.Colors.reset, ctx.model });
    std.debug.print("  {s}Provider:{s}     {s}\n", .{ display.Colors.dim, display.Colors.reset, ctx.provider.name() });
    std.debug.print("  {s}Session:{s}      {s}\n", .{ display.Colors.dim, display.Colors.reset, ctx.session_id });
    std.debug.print("  {s}API Key:{s}      {s}\n", .{ display.Colors.dim, display.Colors.reset, if (ctx.api_key != null) "configured" else "not set" });
    std.debug.print("  {s}Tools:{s}        {d}\n", .{ display.Colors.dim, display.Colors.reset, ctx.tool_names.len });
    std.debug.print("  {s}Skills:{s}       {d}\n", .{ display.Colors.dim, display.Colors.reset, ctx.skill_names.len });
    if (ctx.active_skill) |s| {
        std.debug.print("  {s}Active Skill:{s} {s}\n", .{ display.Colors.dim, display.Colors.reset, s });
    }
    std.debug.print("\n", .{});
}

/// Print available models
pub fn printModels(provider: Provider) void {
    var d = display.Display.init(std.heap.page_allocator);
    d.printHeader("Available Models");
    std.debug.print("\n", .{});
    const models_list = provider.models();
    for (models_list) |m| {
        std.debug.print("  {s}•{s} {s}\n", .{ display.Colors.cyan, display.Colors.reset, m });
    }
    std.debug.print("\n", .{});
    std.debug.print("Use {s}/model <name>{s} to switch.\n\n", .{ display.Colors.cyan, display.Colors.reset });
}

/// Print tool state
pub fn printTools(tool_names: []const []const u8) void {
    var d = display.Display.init(std.heap.page_allocator);
    d.printHeader("Tools");
    std.debug.print("\n", .{});
    for (tool_names, 0..) |name, i| {
        std.debug.print("  {d:>2}. {s}{s}{s}\n", .{ i + 1, display.Colors.green, name, display.Colors.reset });
    }
    std.debug.print("\n", .{});
    std.debug.print("Use {s}/tools enable <name>{s} or {s}/tools disable <name>{s}.\n\n", .{
        display.Colors.cyan, display.Colors.reset,
        display.Colors.cyan, display.Colors.reset,
    });
}

/// Print installed skills
pub fn printSkills(skill_names: []const []const u8, active_skill: ?[]const u8) void {
    var d = display.Display.init(std.heap.page_allocator);
    d.printHeader("Skills");
    std.debug.print("\n", .{});
    if (skill_names.len == 0) {
        std.debug.print("  {s}No skills installed.{s}\n", .{ display.Colors.dim, display.Colors.reset });
    } else {
        for (skill_names) |name| {
            const marker = if (active_skill != null and std.mem.eql(u8, active_skill.?, name)) " *" else "";
            std.debug.print("  {s}•{s} {s}{s}\n", .{ display.Colors.cyan, display.Colors.reset, name, marker });
        }
        if (active_skill) |s| {
            std.debug.print("\n  {s}* Active skill:{s} {s}\n", .{ display.Colors.green, display.Colors.reset, s });
        }
    }
    std.debug.print("\n", .{});
    std.debug.print("Use {s}/skills use <name>{s}, {s}/skills view <name>{s}, or {s}/skills clear{s}.\n\n", .{
        display.Colors.cyan, display.Colors.reset,
        display.Colors.cyan, display.Colors.reset,
        display.Colors.cyan, display.Colors.reset,
    });
}

// ============================================================================
// Interactive terminal menu (raw mode, arrow keys)
// ============================================================================

/// Enable terminal raw mode for interactive input.
/// Returns the original termios to restore on exit.
fn enableRawMode() !std.posix.termios {
    const original = try std.posix.tcgetattr(std.c.STDIN_FILENO);
    var raw = original;
    // Disable canonical mode, echo, and signal generation
    raw.lflag.ECHO = false;
    raw.lflag.ICANON = false;
    raw.lflag.ISIG = false;
    // Minimum characters for non-canonical read: return after 1 char, no timeout
    raw.cc[@intFromEnum(std.posix.V.MIN)] = 1;
    raw.cc[@intFromEnum(std.posix.V.TIME)] = 0;
    try std.posix.tcsetattr(std.c.STDIN_FILENO, .FLUSH, raw);
    return original;
}

fn restoreTerminal(original: std.posix.termios) void {
    std.posix.tcsetattr(std.c.STDIN_FILENO, .FLUSH, original) catch {};
}

/// Run an interactive selection menu.
/// Returns the index of the selected item, or null if cancelled.
pub fn interactiveMenu(
    allocator: std.mem.Allocator,
    title: []const u8,
    items: []const []const u8,
) !?usize {
    _ = allocator;
    const stdout = std.Io.File.stdout();

    const original = enableRawMode() catch return null;
    defer restoreTerminal(original);

    var selected: usize = 0;
    var buf: [16]u8 = undefined;

    while (true) {
        try renderMenu(stdout, title, items, selected);

        const n = std.posix.read(std.c.STDIN_FILENO, &buf) catch break;
        if (n == 0) break;

        switch (buf[0]) {
            '\x1b' => {
                if (n >= 3 and buf[1] == '[') {
                    switch (buf[2]) {
                        'A' => { if (selected > 0) selected -= 1; },
                        'B' => { if (selected < items.len - 1) selected += 1; },
                        else => {},
                    }
                }
            },
            '\r', '\n' => return selected,
            'q', '\x03' => return null,
            else => {},
        }
    }
    return null;
}

fn renderMenu(stdout: std.Io.File, title: []const u8, items: []const []const u8, selected: usize) !void {
    // Build menu into buffer
    var buf: [4096]u8 = undefined;
    var offset: usize = 0;

    const prefix = "\x1b[?25l\x1b[H\x1b[J";
    @memcpy(buf[offset..][0..prefix.len], prefix);
    offset += prefix.len;

    const header = try std.fmt.bufPrint(buf[offset..], "{s}{s}{s}\n\n{s}Up/Down: nav  Enter: pick  q/Esc: back{s}\n\n", .{
        display.Colors.bold, title, display.Colors.reset,
        display.Colors.dim, display.Colors.reset,
    });
    offset += header.len;

    for (items, 0..) |item, i| {
        const line = if (i == selected)
            try std.fmt.bufPrint(buf[offset..], "  {s}▶ {s}{s}\n", .{ display.Colors.cyan, item, display.Colors.reset })
        else
            try std.fmt.bufPrint(buf[offset..], "    {s}{s}{s}\n", .{ display.Colors.dim, item, display.Colors.reset });
        offset += line.len;
    }

    const suffix = "\x1b[?25h";
    @memcpy(buf[offset..][0..suffix.len], suffix);
    offset += suffix.len;

    _ = std.c.write(stdout.handle, &buf, offset);
}

/// Check if terminal supports interactive input (is a TTY)
pub fn supportsInteractive() bool {
    return std.c.isatty(std.c.STDIN_FILENO) != 0;
}

// ============================================================================
// Command history ring buffer
// ============================================================================

const HISTORY_MAX = 100;
var history: [HISTORY_MAX][4096]u8 = undefined;
var history_count: usize = 0;
var history_pos: usize = 0; // next write position (ring)
var history_cursor: ?usize = null; // current position during navigation

/// Add a command to history. Duplicates are not added.
pub fn historyAdd(cmd: []const u8) void {
    if (cmd.len == 0 or cmd.len >= 4096) return;
    // Don't add duplicate of the most recent command
    if (history_count > 0) {
        const prev_idx = if (history_pos == 0) HISTORY_MAX - 1 else history_pos - 1;
        const prev_entry = std.mem.sliceTo(&history[prev_idx], 0);
        if (std.mem.eql(u8, prev_entry, cmd)) return;
    }
    @memcpy(history[history_pos][0..cmd.len], cmd);
    history[history_pos][cmd.len] = 0;
    history_pos = (history_pos + 1) % HISTORY_MAX;
    if (history_count < HISTORY_MAX) history_count += 1;
    history_cursor = null;
}

fn historyPrev(buf: []u8, buf_len: *usize) void {
    if (history_count == 0) return;
    const cursor = history_cursor orelse history_pos;
    const idx = if (cursor == 0) HISTORY_MAX - 1 else cursor - 1;
    // Don't wrap past the oldest entry
    const oldest = if (history_count < HISTORY_MAX) @as(usize, 0) else history_pos;
    if (idx == oldest and history_cursor != null) return;
    if (history_cursor == null and idx == history_pos) return;

    history_cursor = idx;
    const entry = std.mem.sliceTo(&history[idx], 0);
    @memcpy(buf[0..entry.len], entry);
    buf_len.* = entry.len;
}

fn historyNext(buf: []u8, buf_len: *usize) void {
    const cursor = history_cursor orelse return;
    const next = (cursor + 1) % HISTORY_MAX;
    if (next == history_pos) {
        history_cursor = null;
        buf_len.* = 0;
        return;
    }
    history_cursor = next;
    const entry = std.mem.sliceTo(&history[next], 0);
    @memcpy(buf[0..entry.len], entry);
    buf_len.* = entry.len;
}

// ============================================================================
// Interactive line reader with raw mode
// ============================================================================

/// Read a line of input with basic editing and history.
/// Falls back to simple line-mode if terminal doesn't support raw mode.
pub fn readLine(prompt: []const u8) !?[]const u8 {
    if (!supportsInteractive()) {
        return readLineSimple(prompt);
    }

    const original = enableRawMode() catch return readLineSimple(prompt);
    defer restoreTerminal(original);

    var buf: [4096]u8 = undefined;
    var len: usize = 0;

    // Show prompt using raw write to stdout
    _ = std.c.write(std.c.STDOUT_FILENO, prompt.ptr, prompt.len);

    while (true) {
        var char_buf: [4]u8 = undefined;
        const n = std.posix.read(std.c.STDIN_FILENO, &char_buf) catch break;
        if (n == 0) break;

        const c = char_buf[0];
        switch (c) {
            '\r', '\n' => {
                _ = std.c.write(std.c.STDOUT_FILENO, "\r\n", 2);
                historyAdd(buf[0..len]);
                return try std.heap.page_allocator.dupe(u8, buf[0..len]);
            },
            '\x03' => { // Ctrl-C
                _ = std.c.write(std.c.STDOUT_FILENO, "^C\r\n", 4);
                return null;
            },
            '\x04' => { // Ctrl-D (EOF)
                if (len == 0) {
                    _ = std.c.write(std.c.STDOUT_FILENO, "\r\n", 2);
                    return null;
                }
            },
            '\x7f' => { // Backspace
                if (len > 0) {
                    len -= 1;
                    _ = std.c.write(std.c.STDOUT_FILENO, "\x08 \x08", 3);
                }
            },
            '\x1b' => { // Escape sequence
                if (n >= 3 and char_buf[1] == '[') {
                    switch (char_buf[2]) {
                        'A' => { // Up arrow - history prev
                            _ = std.c.write(std.c.STDOUT_FILENO, "\r\x1b[K", 4);
                            _ = std.c.write(std.c.STDOUT_FILENO, prompt.ptr, prompt.len);
                            historyPrev(&buf, &len);
                            _ = std.c.write(std.c.STDOUT_FILENO, buf[0..len].ptr, len);
                        },
                        'B' => { // Down arrow - history next
                            _ = std.c.write(std.c.STDOUT_FILENO, "\r\x1b[K", 4);
                            _ = std.c.write(std.c.STDOUT_FILENO, prompt.ptr, prompt.len);
                            historyNext(&buf, &len);
                            _ = std.c.write(std.c.STDOUT_FILENO, buf[0..len].ptr, len);
                        },
                        'C' => {}, // Right arrow (ignore in simple mode)
                        'D' => {}, // Left arrow (ignore)
                        else => {},
                    }
                }
            },
            else => {
                if (c >= 0x20 and c <= 0x7E and len < buf.len - 1) {
                    buf[len] = c;
                    len += 1;
                    _ = std.c.write(std.c.STDOUT_FILENO, buf[len - 1 .. len].ptr, 1);
                }
            },
        }
    }
    return null;
}

fn readLineSimple(prompt: []const u8) !?[]const u8 {
    var buf: [4096]u8 = undefined;
    const stdin = std.Io.File.stdin();
    var reader = stdin.reader(std.Io.Threaded.global_single_threaded.io(), &buf);

    std.debug.print("{s}", .{prompt});
    const n = reader.interface.readSliceShort(&buf) catch |err| {
        if (err == error.EndOfStream) return null;
        return null;
    };
    if (n == 0) return null;
    const trimmed = std.mem.trim(u8, buf[0..n], "\r\n");
    const result = try std.heap.page_allocator.dupe(u8, trimmed);
    historyAdd(trimmed);
    return result;
}

// ============================================================================
// Tests
// ============================================================================

test "parseCommand: empty input" {
    try std.testing.expectEqual(.none, parseCommand(std.testing.allocator, ""));
    try std.testing.expectEqual(.none, parseCommand(std.testing.allocator, "   "));
    try std.testing.expectEqual(.none, parseCommand(std.testing.allocator, "hello"));
}

test "parseCommand: /help" {
    try std.testing.expectEqual(.show_help, parseCommand(std.testing.allocator, "/help"));
    try std.testing.expectEqual(.show_help, parseCommand(std.testing.allocator, "/h"));
}

test "parseCommand: /quit" {
    try std.testing.expectEqual(.quit, parseCommand(std.testing.allocator, "/quit"));
    try std.testing.expectEqual(.quit, parseCommand(std.testing.allocator, "/exit"));
    try std.testing.expectEqual(.quit, parseCommand(std.testing.allocator, "/q"));
}

test "parseCommand: /new" {
    try std.testing.expectEqual(.new_session, parseCommand(std.testing.allocator, "/new"));
    try std.testing.expectEqual(.new_session, parseCommand(std.testing.allocator, "/clear"));
}

test "parseCommand: /config" {
    try std.testing.expectEqual(.show_config, parseCommand(std.testing.allocator, "/config"));
}

test "parseCommand: /model" {
    try std.testing.expectEqual(.show_models, parseCommand(std.testing.allocator, "/model"));
}

test "parseCommand: /model with name" {
    var action = parseCommand(std.testing.allocator, "/model gpt-4o");
    defer deinitAction(&action, std.testing.allocator);
    try std.testing.expect(action == .switch_model);
    try std.testing.expectEqualStrings("gpt-4o", action.switch_model);
}

test "parseCommand: /tools" {
    try std.testing.expectEqual(.show_tools, parseCommand(std.testing.allocator, "/tools"));
    try std.testing.expectEqual(.show_tools, parseCommand(std.testing.allocator, "/tools list"));
}

test "parseCommand: /tools enable" {
    var action = parseCommand(std.testing.allocator, "/tools enable shell");
    defer deinitAction(&action, std.testing.allocator);
    try std.testing.expect(action == .toggle_tool);
    try std.testing.expectEqualStrings("shell", action.toggle_tool.name);
    try std.testing.expect(action.toggle_tool.enable);
}

test "parseCommand: /tools disable" {
    var action = parseCommand(std.testing.allocator, "/tools disable shell");
    defer deinitAction(&action, std.testing.allocator);
    try std.testing.expect(action == .toggle_tool);
    try std.testing.expectEqualStrings("shell", action.toggle_tool.name);
    try std.testing.expect(!action.toggle_tool.enable);
}

test "parseCommand: /skills" {
    try std.testing.expectEqual(.show_skills, parseCommand(std.testing.allocator, "/skills"));
}

test "parseCommand: /skills use" {
    var action = parseCommand(std.testing.allocator, "/skills use poetry-helper");
    defer deinitAction(&action, std.testing.allocator);
    try std.testing.expect(action == .use_skill);
    try std.testing.expectEqualStrings("poetry-helper", action.use_skill);
}

test "parseCommand: /skills clear" {
    try std.testing.expectEqual(.clear_skill, parseCommand(std.testing.allocator, "/skills clear"));
}

test "parseCommand: /skills view" {
    var action = parseCommand(std.testing.allocator, "/skills view my-skill");
    defer deinitAction(&action, std.testing.allocator);
    try std.testing.expect(action == .view_skill);
    try std.testing.expectEqualStrings("my-skill", action.view_skill);
}

test "parseCommand: handles newlines in input" {
    const action = parseCommand(std.testing.allocator, "/new\n/quit\n");
    try std.testing.expectEqual(.new_session, action);
}

test "parseCommand: trims whitespace from args" {
    var action = parseCommand(std.testing.allocator, "/model   gpt-4o  \n");
    defer deinitAction(&action, std.testing.allocator);
    try std.testing.expect(action == .switch_model);
    try std.testing.expectEqualStrings("gpt-4o", action.switch_model);
}

test "getCommands returns all commands" {
    const cmds = getCommands();
    try std.testing.expect(cmds.len >= 10);
}

test "supportsInteractive returns bool" {
    _ = supportsInteractive();
}
