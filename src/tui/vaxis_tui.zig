//! Vaxis-based terminal UI for knot3bot.
//!
//! Provides a professional TUI with:
//! - Chat message area with scrollback
//! - Input line with history navigation
//! - Status bar showing provider/model/session/tokens
//! - Slash command overlay
//! - Interactive menus for model/tool/skills selection

const std = @import("std");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

const CliAction = @import("../cli.zig").CliAction;
const Provider = @import("../root.zig").providers.Provider;

/// Maximum scrollback lines in chat area
const SCROLLBACK_MAX = 5000;

/// Application state
pub const App = struct {
    allocator: std.mem.Allocator,

    // Chat messages
    messages: std.ArrayList(Message),
    scroll_offset: usize = 0,

    // Input state
    input_buf: [4096]u8 = [_]u8{0} ** 4096,
    input_len: usize = 0,
    cursor_pos: usize = 0,

    // Command mode
    command_mode: bool = false,
    command_buf: [256]u8 = [_]u8{0} ** 256,
    command_len: usize = 0,

    // History
    history: std.ArrayList([4096]u8),
    history_idx: ?usize = null,

    // Config display
    provider: Provider = .openai,
    model: []const u8 = "",
    session_id: []const u8 = "default",
    tools_count: usize = 0,
    skills_count: usize = 0,
    token_usage: TokenUsage = .{},

    // Streaming response buffer
    streaming: bool = false,
    stream_buf: std.ArrayList(u8),

    // Overlays
    show_help: bool = false,
    show_models: bool = false,
    show_tools: bool = false,
    show_skills: bool = false,
    show_config: bool = false,
    menu_items: std.ArrayList([]const u8),
    menu_selected: usize = 0,
    menu_title: []const u8 = "",

    // Action queue (returned to caller)
    pending_action: ?CliAction = null,

    // Exit flag
    should_quit: bool = false,

    pub const Message = struct {
        role: Role,
        content: []const u8,
        time: i64,

        pub const Role = enum { user, assistant, system, tool, err };
    };

    pub const TokenUsage = struct {
        prompt: u32 = 0,
        completion: u32 = 0,
        total: u32 = 0,
    };

    pub fn init(allocator: std.mem.Allocator) !App {
        return App{
            .allocator = allocator,
            .messages = std.ArrayList(Message).init(allocator),
            .history = std.ArrayList([4096]u8).init(allocator),
            .stream_buf = std.ArrayList(u8).init(allocator),
            .menu_items = std.ArrayList([]const u8).init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit();
        self.history.deinit();
        self.stream_buf.deinit();
        self.menu_items.deinit();
    }

    // --- Public API for main.zig to push data ---

    pub fn addMessage(self: *App, role: Message.Role, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        try self.messages.append(.{ .role = role, .content = owned, .time = std.time.timestamp() });
        self.scroll_offset = 0; // auto-scroll to bottom
    }

    pub fn addToHistory(self: *App, cmd: []const u8) !void {
        if (cmd.len == 0 or cmd.len >= 4096) return;
        var entry: [4096]u8 = [_]u8{0} ** 4096;
        @memcpy(entry[0..cmd.len], cmd);
        try self.history.append(entry);
        self.history_idx = null;
    }

    pub fn setStreaming(self: *App, active: bool) void {
        self.streaming = active;
        if (!active) {
            // Flush stream buffer as a message
            if (self.stream_buf.items.len > 0) {
                const content = self.allocator.dupe(u8, self.stream_buf.items) catch return;
                self.messages.append(.{ .role = .assistant, .content = content, .time = std.time.timestamp() }) catch return;
                self.stream_buf.clearRetainingCapacity();
            }
        }
    }

    pub fn appendStreamChunk(self: *App, chunk: []const u8) !void {
        try self.stream_buf.appendSlice(chunk);
        self.scroll_offset = 0;
    }

    /// Read a pending action (non-blocking, returns null if no action queued)
    pub fn takeAction(self: *App) ?CliAction {
        const action = self.pending_action;
        self.pending_action = null;
        return action;
    }

    pub fn quit(self: *App) void {
        self.should_quit = true;
    }

    // --- vxfw Widget interface ---

    pub fn widget(self: *App) vxfw.VaWid {
        return vxfw.VaWid.init(Widget{ .app = self });
    }

    pub const Widget = struct {
        app: *App,

        pub fn build(self_2: *const Widget, ctx: vxfw.BuildContext) vxfw.BuildResult {
            const app = self_2.app;
            return .{ .surface = buildUI(app, ctx.max) catch |err| {
                const msg = try std.fmt.allocPrint(app.allocator, "UI error: {}", .{err});
                defer app.allocator.free(msg);
                return .{ .surface = vaxis.Surface.init(app.allocator, ctx.max.width, ctx.max.height) catch return .{ .consume_event = false } };
            }, .consume_event = true };
        }

        pub fn handleEvent(self_2: *Widget, event: vxfw.Event, ctx: vxfw.EventContext) vxfw.EventResult {
            _ = ctx;
            return switch (event) {
                .key_press => |key| handleKey(self_2.app, key),
                .mouse => |mouse| handleMouse(self_2.app, mouse),
                .winsize => |ws| handleResize(self_2.app, ws),
                else => .ignore,
            };
        }
    };
};

// --- UI Rendering ---

fn buildUI(app: *App, max: vxfw.MaxSize) !vaxis.Surface {
    var surface = try vaxis.Surface.init(app.allocator, max.width orelse 80, max.height orelse 24);
    const w = surface.width();
    const h = surface.height();

    // Layout: 3 rows — status bar (1), chat area (h-3), input bar (2)
    if (h < 5) {
        _ = surface.printString(0, 0, "Terminal too small", .{ .fg = .red });
        return surface;
    }

    const chat_top: usize = 1;
    const chat_bottom: usize = h - 2;
    const input_row: usize = h - 2;

    // 1. Status bar
    renderStatusBar(app, &surface, w);

    // 2. Chat area
    renderChat(app, &surface, w, chat_top, chat_bottom);

    // 3. Input bar
    renderInputBar(app, &surface, w, input_row);

    // 4. Overlays
    if (app.show_help) renderHelpOverlay(app, &surface, w, h);
    if (app.show_models) renderMenuOverlay(app, &surface, w, h, "Select Model", app.menu_items.items, app.menu_selected);
    if (app.show_tools) renderMenuOverlay(app, &surface, w, h, "Tools", app.menu_items.items, app.menu_selected);
    if (app.show_skills) renderMenuOverlay(app, &surface, w, h, "Skills", app.menu_items.items, app.menu_selected);
    if (app.show_config) renderConfigOverlay(app, &surface, w, h);

    return surface;
}

fn renderStatusBar(app: *App, surface: *vaxis.Surface, w: usize) void {
    const style = vaxis.Style{ .fg = .{ .index = 0 }, .bg = .{ .index = 8 } };
    surface.fillRow(0, style);

    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " {s} | {s} | S:{s} | T:{d}P+{d}C ",
        .{ app.provider.name(), app.model, app.session_id, app.token_usage.prompt, app.token_usage.completion }) catch return;
    _ = surface.printString(0, 0, text, .{ .fg = .white, .bg = .{ .rgb = .{ 0x30, 0x30, 0x40 } } });

    // Right side: streaming indicator + quit hint
    if (app.streaming) {
        const right = " STREAMING Ctrl-C:quit ";
        if (w > text.len + right.len) {
            _ = surface.printString(w - right.len, 0, right, .{ .fg = .yellow, .bg = .{ .rgb = .{ 0x40, 0x30, 0x30 } } });
        }
    }
}

fn renderChat(app: *App, surface: *vaxis.Surface, w: usize, top: usize, bottom: usize) void {
    const area_height = bottom - top;
    if (area_height == 0) return;

    // Collect visible lines (newest at bottom)
    var lines = std.ArrayList(Line).init(app.allocator);
    defer lines.deinit();

    // First add streaming content if active
    if (app.streaming and app.stream_buf.items.len > 0) {
        try wrapText(app.stream_buf.items, w - 4, &lines, .assistant);
    }

    // Then messages from newest to oldest until we fill the area
    var msg_idx: usize = if (app.messages.items.len > 0) app.messages.items.len - 1 else 0;
    var found_lines: usize = lines.items.len;
    while (found_lines < area_height + app.scroll_offset and msg_idx < app.messages.items.len) {
        const msg = app.messages.items[msg_idx];
        try wrapText(msg.content, w - 4, &lines, msg.role);
        if (msg_idx == 0) break;
        msg_idx -= 1;
        found_lines = lines.items.len;
    }

    // Apply scroll offset
    const start_line = if (lines.items.len > area_height)
        @min(app.scroll_offset, lines.items.len - area_height)
    else
        0;

    var row: usize = top;
    for (lines.items[start_line..@min(lines.items.len, start_line + area_height)]) |line| {
        const style: vaxis.Style = switch (line.role) {
            .user => .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } } },
            .assistant => .{ .fg = .{ .rgb = .{ 0xD1, 0xD5, 0xDB } } },
            .system => .{ .fg = .{ .rgb = .{ 0xF5, 0x9E, 0x0B } } },
            .tool => .{ .fg = .{ .rgb = .{ 0x9C, 0xA3, 0xAF } } },
            .err => .{ .fg = .{ .rgb = .{ 0xEF, 0x44, 0x44 } } },
        };
        const prefix: []const u8 = switch (line.role) {
            .user => "  > ",
            .assistant => "    ",
            .system => "  ~ ",
            .tool => "  * ",
            .err => "  ! ",
        };
        _ = surface.printString(0, row, prefix, .{ .fg = .{ .index = 8 } });
        _ = surface.printString(4, row, line.text, style);
        row += 1;
    }
}

const Line = struct { text: []const u8, role: App.Message.Role };

fn wrapText(text: []const u8, max_width: usize, lines: *std.ArrayList(Line), role: App.Message.Role) !void {
    if (text.len == 0) return;
    var pos: usize = 0;
    while (pos < text.len) {
        var end = @min(pos + max_width, text.len);
        // Try to break at word boundary
        if (end < text.len) {
            var scan = end;
            while (scan > pos and text[scan] != ' ' and text[scan] != '\n') scan -= 1;
            if (scan > pos + max_width / 2) end = scan;
        }
        // Handle explicit newlines
        if (std.mem.indexOfScalar(u8, text[pos..end], '\n')) |nl| {
            end = pos + nl;
        }
        try lines.append(.{ .text = text[pos..end], .role = role });
        pos = end;
        if (pos < text.len and text[pos] == '\n') pos += 1;
        if (pos < text.len and text[pos] == ' ') pos += 1;
    }
}

fn renderInputBar(app: *App, surface: *vaxis.Surface, w: usize, row: usize) void {
    // Separator line
    surface.fillRow(row, .{ .bg = .{ .index = 8 } });

    const prompt = if (app.command_mode) "/" else "> ";
    const text = if (app.command_mode) app.command_buf[0..app.command_len] else app.input_buf[0..app.input_len];

    var buf: [4096]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, "{s}{s}", .{ prompt, text }) catch return;
    _ = surface.printString(0, row + 1, line, .{ .fg = .white });

    // Cursor
    const cursor_x = prompt.len + app.cursor_pos;
    if (cursor_x < w) {
        _ = surface.printString(cursor_x, row + 1, " ", .{ .bg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } } });
    }
}

// --- Overlays ---

fn renderHelpOverlay(app: *App, surface: *vaxis.Surface, w: usize, h: usize) void {
    _ = app;
    const cmds = [_][]const u8{
        "/help           Show this help",
        "/model [name]   Switch or list models",
        "/config         Show configuration",
        "/tools          Toggle tools",
        "/skills         Manage skills",
        "/new            New session",
        "/quit           Exit",
        "ESC             Close overlay",
    };
    const ow = 45;
    const oh = cmds.len + 4;
    const ox = (w - ow) / 2;
    const oy = (h - oh) / 2;

    drawOverlayBox(surface, ox, oy, ow, oh);
    _ = surface.printString(ox + 2, oy + 1, "knot3bot Commands", .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true });
    for (cmds, 0..) |cmd, i| {
        _ = surface.printString(ox + 2, oy + 3 + i, cmd, .{ .fg = .white });
    }
}

fn renderMenuOverlay(app: *App, surface: *vaxis.Surface, w: usize, h: usize, title: []const u8, items: []const []const u8, selected: usize) void {
    _ = app;
    const ow = 40;
    const oh = @min(items.len + 4, h - 4);
    const ox = (w - ow) / 2;
    const oy = (h - oh) / 2;

    drawOverlayBox(surface, ox, oy, ow, oh);
    _ = surface.printString(ox + 2, oy + 1, title, .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true });

    const start = @max(selected, @min(selected, oh - 4)) - @min(selected, oh - 4);
    for (items[start..@min(items.len, start + oh - 3)], 0..) |item, i| {
        const idx = start + i;
        if (idx == selected) {
            _ = surface.printString(ox + 1, oy + 3 + i, ">", .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } } });
        }
        _ = surface.printString(ox + 3, oy + 3 + i, item, if (idx == selected) .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true } else .{ .fg = .white });
    }
    _ = surface.printString(ox + 2, oy + oh - 2, "↑↓:nav Enter:pick Esc:back", .{ .fg = .{ .index = 8 } });
}

fn renderConfigOverlay(app: *App, surface: *vaxis.Surface, w: usize, h: usize) void {
    const ow = 45;
    const oh = 10;
    const ox = (w - ow) / 2;
    const oy = (h - oh) / 2;

    drawOverlayBox(surface, ox, oy, ow, oh);
    _ = surface.printString(ox + 2, oy + 1, "Configuration", .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true });

    var buf: [128]u8 = undefined;
    const lines = [_][]const u8{
        std.fmt.bufPrint(&buf, "Provider:  {s}", .{app.provider.name()}) catch "",
        std.fmt.bufPrint(&buf, "Model:     {s}", .{app.model}) catch "",
        std.fmt.bufPrint(&buf, "Session:   {s}", .{app.session_id}) catch "",
        std.fmt.bufPrint(&buf, "Tools:     {d}", .{app.tools_count}) catch "",
        std.fmt.bufPrint(&buf, "Skills:    {d}", .{app.skills_count}) catch "",
        std.fmt.bufPrint(&buf, "Tokens:    {d}P + {d}C", .{app.token_usage.prompt, app.token_usage.completion}) catch "",
        "ESC: close",
    };
    for (lines, 0..) |line, i| {
        _ = surface.printString(ox + 2, oy + 3 + i, line, .{ .fg = .white });
    }
}

fn drawOverlayBox(surface: *vaxis.Surface, _: usize, y: usize, _: usize, h: usize) void {
    const bg = vaxis.Style{ .bg = .{ .rgb = .{ 0x1F, 0x29, 0x37 } } };
    for (0..h) |row| {
        surface.fillRow(y + row, bg);
    }
}

// --- Input Handling ---

fn handleKey(app: *App, key: vaxis.Key) vxfw.EventResult {
    // Global: ESC to close overlays
    if (key.matches('q', .{ .ctrl = true }) or key.matches('c', .{ .ctrl = true })) {
        app.quit();
        return .consumed;
    }

    if (key.matches(vaxis.Key.escape, .{})) {
        if (app.show_help or app.show_models or app.show_tools or app.show_skills or app.show_config) {
            app.show_help = false;
            app.show_models = false;
            app.show_tools = false;
            app.show_skills = false;
            app.show_config = false;
            return .consumed;
        }
        if (app.command_mode) {
            app.command_mode = false;
            app.command_len = 0;
            return .consumed;
        }
        return .consumed;
    }

    // Overlay navigation
    if (app.show_models or app.show_tools or app.show_skills) {
        return handleMenuNavigation(app, key);
    }

    // Command mode
    if (app.command_mode) {
        return handleCommandInput(app, key);
    }

    // Normal input mode
    return handleNormalInput(app, key);
}

fn handleMenuNavigation(app: *App, key: vaxis.Key) vxfw.EventResult {
    const count = app.menu_items.items.len;
    if (key.matches(vaxis.Key.up, .{})) {
        if (app.menu_selected > 0) app.menu_selected -= 1;
        return .consumed;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        if (app.menu_selected < count - 1) app.menu_selected += 1;
        return .consumed;
    }
    if (key.matches(vaxis.Key.enter, .{})) {
        if (app.menu_selected < count) {
            app.pending_action = .{ .send_message = app.allocator.dupe(u8, app.menu_items.items[app.menu_selected]) catch return .consumed };
        }
        app.show_models = false;
        app.show_tools = false;
        app.show_skills = false;
        return .consumed;
    }
    return .consumed;
}

fn handleCommandInput(app: *App, key: vaxis.Key) vxfw.EventResult {
    if (key.matches(vaxis.Key.enter, .{})) {
        const cmd = app.command_buf[0..app.command_len];
        app.command_mode = false;
        app.command_len = 0;
        processCommand(app, cmd);
        return .consumed;
    }
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (app.command_len > 0) app.command_len -= 1;
        return .consumed;
    }
    if (key.codepoint >= 0x20 and key.codepoint <= 0x7E and app.command_len < app.command_buf.len) {
        app.command_buf[app.command_len] = @intCast(key.codepoint);
        app.command_len += 1;
        return .consumed;
    }
    return .consumed;
}

fn handleNormalInput(app: *App, key: vaxis.Key) vxfw.EventResult {
    // '/' enters command mode
    if (key.codepoint == '/' and app.input_len == 0) {
        app.command_mode = true;
        app.command_len = 0;
        return .consumed;
    }

    // Enter: send message
    if (key.matches(vaxis.Key.enter, .{})) {
        const text = app.input_buf[0..app.input_len];
        if (text.len > 0) {
            // Copy to heap for action
            const owned = app.allocator.dupe(u8, text) catch return .consumed;
            app.addToHistory(text) catch {};
            app.input_len = 0;
            app.cursor_pos = 0;
            app.pending_action = .{ .send_message = owned };
        }
        return .consumed;
    }

    // Backspace
    if (key.matches(vaxis.Key.backspace, .{})) {
        if (app.input_len > 0 and app.cursor_pos > 0) {
            const pos = app.cursor_pos - 1;
            for (pos..app.input_len - 1) |i| {
                app.input_buf[i] = app.input_buf[i + 1];
            }
            app.input_len -= 1;
            app.cursor_pos = pos;
        }
        return .consumed;
    }

    // Delete
    if (key.matches(vaxis.Key.delete, .{})) {
        if (app.cursor_pos < app.input_len) {
            for (app.cursor_pos..app.input_len - 1) |i| {
                app.input_buf[i] = app.input_buf[i + 1];
            }
            app.input_len -= 1;
        }
        return .consumed;
    }

    // Arrow keys
    if (key.matches(vaxis.Key.left, .{})) {
        if (app.cursor_pos > 0) app.cursor_pos -= 1;
        return .consumed;
    }
    if (key.matches(vaxis.Key.right, .{})) {
        if (app.cursor_pos < app.input_len) app.cursor_pos += 1;
        return .consumed;
    }
    if (key.matches(vaxis.Key.up, .{})) {
        // History navigation
        if (app.history_idx == null and app.history.items.len > 0) {
            app.history_idx = app.history.items.len - 1;
        } else if (app.history_idx) |idx| {
            if (idx > 0) app.history_idx = idx - 1;
        }
        if (app.history_idx) |idx| {
            const entry = std.mem.sliceTo(&app.history.items[idx], 0);
            @memcpy(app.input_buf[0..entry.len], entry);
            app.input_len = entry.len;
            app.cursor_pos = entry.len;
        }
        return .consumed;
    }
    if (key.matches(vaxis.Key.down, .{})) {
        if (app.history_idx) |idx| {
            if (idx + 1 < app.history.items.len) {
                app.history_idx = idx + 1;
                const entry = std.mem.sliceTo(&app.history.items[idx + 1], 0);
                @memcpy(app.input_buf[0..entry.len], entry);
                app.input_len = entry.len;
                app.cursor_pos = entry.len;
            } else {
                app.history_idx = null;
                app.input_len = 0;
                app.cursor_pos = 0;
            }
        }
        return .consumed;
    }

    // Page Up/Down: scroll
    if (key.matches(vaxis.Key.page_up, .{})) {
        app.scroll_offset += 10;
        return .consumed;
    }
    if (key.matches(vaxis.Key.page_down, .{})) {
        if (app.scroll_offset >= 10) app.scroll_offset -= 10 else app.scroll_offset = 0;
        return .consumed;
    }

    // Normal character input
    if (key.codepoint >= 0x20 and key.codepoint <= 0x7E and app.input_len < app.input_buf.len - 1) {
        // Insert at cursor position
        var pos = app.input_len;
        while (pos > app.cursor_pos) : (pos -= 1) {
            app.input_buf[pos] = app.input_buf[pos - 1];
        }
        app.input_buf[app.cursor_pos] = @intCast(key.codepoint);
        app.input_len += 1;
        app.cursor_pos += 1;
        return .consumed;
    }

    return .consumed;
}

fn handleMouse(app: *App, mouse: vaxis.Mouse) vxfw.EventResult {
    _ = app;
    _ = mouse;
    return .ignore;
}

fn handleResize(app: *App, ws: vaxis.Winsize) vxfw.EventResult {
    _ = app;
    _ = ws;
    return .consumed;
}

// --- Command Processing ---

fn processCommand(app: *App, cmd: []const u8) void {
    const trimmed = std.mem.trim(u8, cmd, " \t");
    if (trimmed.len == 0) return;

    // Dispatch based on command
    if (std.mem.eql(u8, trimmed, "help") or std.mem.eql(u8, trimmed, "h")) {
        app.show_help = true;
    } else if (std.mem.eql(u8, trimmed, "quit") or std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "q")) {
        app.quit();
    } else if (std.mem.eql(u8, trimmed, "new") or std.mem.eql(u8, trimmed, "clear")) {
        app.pending_action = .new_session;
    } else if (std.mem.eql(u8, trimmed, "config")) {
        app.show_config = true;
    } else if (std.mem.eql(u8, trimmed, "model")) {
        // Would need to populate menu from caller
        app.show_models = true;
    } else if (std.mem.eql(u8, trimmed, "tools")) {
        app.show_tools = true;
    } else if (std.mem.eql(u8, trimmed, "skills")) {
        app.show_skills = true;
    } else {
        // Unknown command — treat as message
        const owned = app.allocator.dupe(u8, cmd) catch return;
        app.pending_action = .{ .send_message = owned };
    }
}

// --- Run loop ---

/// Run the TUI event loop. Returns when user quits or Ctrl-C.
/// Caller should call takeAction() to get any pending action after each frame.
pub fn run(app: *App) !void {
    var vx = try vaxis.init(app.allocator, .{});
    defer vx.deinit(app.allocator);

    var loop: vaxis.Loop(vxfw.Event) = .{
        .vaxis = &vx,
        .user_data = app,
    };
    try loop.init();

    try vx.startReadThread(app.allocator);
    defer vx.stopReadThread();

    // Initial render
    try loop.redraw();

    while (!app.should_quit) {
        const event = loop.nextEvent();
        switch (event) {
            .key_press => |key| {
                _ = handleKey(app, key);
            },
            .mouse => |mouse| {
                _ = handleMouse(app, mouse);
            },
            .winsize => |ws| {
                _ = handleResize(app, ws);
            },
            else => {},
        }
        try loop.redraw();
    }
}
