//! knot3bot terminal UI using libvaxis.
//! Low-level vaxis API — no vxfw dependency.

const std = @import("std");
const vaxis = @import("vaxis");

pub const Role = enum { user, assistant, system, tool, err };

pub const Message = struct {
    role: Role,
    content: []const u8,
};

pub const App = struct {
    allocator: std.mem.Allocator,
    vx: vaxis.Vaxis,
    tty: vaxis.Tty,
    loop: vaxis.Loop(vaxis.Event),

    // Messages
    messages: std.array_list.AlignedManaged(Message, null),
    scroll_offset: usize = 0,

    // Input
    input_buf: [4096]u8 = [_]u8{0} ** 4096,
    input_len: usize = 0,
    cursor_pos: usize = 0,

    // Command mode
    command_mode: bool = false,
    command_buf: [256]u8 = [_]u8{0} ** 256,
    command_len: usize = 0,

    // History
    history: std.array_list.AlignedManaged([4096]u8, null),
    history_idx: ?usize = null,

    // Status
    provider_name: []const u8 = "",
    model_name: []const u8 = "",
    session_id: []const u8 = "default",
    tools_count: usize = 0,
    token_prompt: u32 = 0,
    token_completion: u32 = 0,

    // Streaming
    streaming: bool = false,
    stream_buf: std.array_list.AlignedManaged(u8, null),

    // Overlays
    show_help: bool = false,
    show_models: bool = false,
    show_tools: bool = false,
    show_skills: bool = false,
    show_config: bool = false,
    menu_items: std.array_list.AlignedManaged([]const u8, null),
    menu_selected: usize = 0,
    menu_title: []const u8 = "",

    // Actions
    pending_action: ?Action = null,
    should_quit: bool = false,

    pub const Action = union(enum) {
        quit,
        new_session,
        send_message: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !App {
        var tty_buf: [4096]u8 = undefined;
        return App{
            .allocator = allocator,
            .vx = try vaxis.init(io, allocator, env_map, .{}),
            .tty = try vaxis.Tty.init(io, &tty_buf),
            .loop = undefined,
            .messages = std.array_list.AlignedManaged(Message, null).init(allocator),
            .history = std.array_list.AlignedManaged([4096]u8, null).init(allocator),
            .stream_buf = std.array_list.AlignedManaged(u8, null).init(allocator),
            .menu_items = std.array_list.AlignedManaged([]const u8, null).init(allocator),
        };
    }

    pub fn deinit(self: *App) void {
        for (self.messages.items) |msg| self.allocator.free(msg.content);
        self.messages.deinit();
        self.history.deinit();
        self.stream_buf.deinit();
        self.menu_items.deinit();
    }

    pub fn start(self: *App) !void {
        self.loop = .init(std.Io.Threaded.global_single_threaded.io(), &self.tty, &self.vx);
        try self.vx.enterAltScreen(self.tty.writer());
        try self.vx.queryTerminal(self.tty.writer(), .{ .nanoseconds = 500_000_000 });
        try self.vx.enableDetectedFeatures(self.tty.writer());
        try self.loop.start();
    }

    pub fn stop(self: *App) void {
        self.loop.stop();
        self.vx.exitAltScreen(self.tty.writer()) catch {};
        self.vx.deinit(self.allocator, self.tty.writer());
        self.tty.deinit();
    }

    pub fn addMessage(self: *App, role: Role, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        try self.messages.append(.{ .role = role, .content = owned });
        self.scroll_offset = 0;
    }

    pub fn addHistory(self: *App, cmd: []const u8) !void {
        if (cmd.len == 0 or cmd.len >= 4096) return;
        var entry: [4096]u8 = [_]u8{0} ** 4096;
        @memcpy(entry[0..cmd.len], cmd);
        try self.history.append(entry);
        self.history_idx = null;
    }

    pub fn takeAction(self: *App) ?Action {
        const a = self.pending_action;
        self.pending_action = null;
        return a;
    }

    pub fn quit(self: *App) void { self.should_quit = true; }

    /// Render the UI
    pub fn renderFrame(self: *App) !void {
        const w = self.vx.screen.width;
        const h = self.vx.screen.height;
        if (h < 5) return;

        const win = self.vx.window();

        // ── Status bar ──
        const status_bg: vaxis.Cell.Color = .{ .index = 8 };
        var status_win = win.child(.{ .x_off = 0, .y_off = 0, .width = w, .height = 1 });
        status_win.fill(.{ .style = .{ .bg = status_bg } });

        var status_buf: [256]u8 = undefined;
        const status = std.fmt.bufPrint(&status_buf, " {s} | {s} | S:{s} | T:{d}P+{d}C ",
            .{ self.provider_name, self.model_name, self.session_id, self.token_prompt, self.token_completion }) catch " knot3bot ";
        _ = status_win.printSegment(.{ .text = status, .style = .{ .fg = .default, .bg = status_bg } }, .{});

        if (self.streaming) {
            const right = " STREAMING Ctrl-C:quit ";
            if (w > status.len + right.len) {
                _ = status_win.printSegment(.{ .text = right, .style = .{ .fg = .{ .index = 3 }, .bg = .{ .rgb = .{ 0x40, 0x30, 0x30 } } } },
                    .{ .col_offset = w -| @as(u16, @intCast(right.len)) });
            }
        }

        // ── Chat area ──
        const chat_top: u16 = 1;
        const chat_bottom: u16 = h - 2;
        const area_h = chat_bottom - chat_top;

        var visible_lines = std.array_list.AlignedManaged(VisibleLine, null).init(self.allocator);
        defer visible_lines.deinit();

        if (self.streaming and self.stream_buf.items.len > 0) {
            try wrapLines(self.stream_buf.items, w, &visible_lines, .assistant);
        }
        var idx: usize = if (self.messages.items.len > 0) self.messages.items.len - 1 else 0;
        while (visible_lines.items.len < area_h + self.scroll_offset and idx < self.messages.items.len) : (idx -|= 1) {
            try wrapLines(self.messages.items[idx].content, w, &visible_lines, self.messages.items[idx].role);
            if (idx == 0) break;
        }

        const scroll_start = @min(self.scroll_offset, @max(0, @as(usize, @intCast(visible_lines.items.len)) -| area_h));
        var row: u16 = chat_top;
        var line_idx: usize = scroll_start;
        while (row < chat_bottom and line_idx < visible_lines.items.len) : (line_idx += 1) {
            const line = visible_lines.items[line_idx];
            const prefix: []const u8 = switch (line.role) {
                .user => "> ", .assistant => "  ", .system => "~ ", .tool => "* ", .err => "! ",
            };
            const color: vaxis.Cell.Color = switch (line.role) {
                .user => .{ .rgb = .{ 0x22, 0xD3, 0xEE } },
                .assistant => .{ .rgb = .{ 0xD1, 0xD5, 0xDB } },
                .system => .{ .rgb = .{ 0xF5, 0x9E, 0x0B } },
                .tool => .{ .rgb = .{ 0x9C, 0xA3, 0xAF } },
                .err => .{ .rgb = .{ 0xEF, 0x44, 0x44 } },
            };
            var line_win = win.child(.{ .x_off = 0, .y_off = @intCast(row), .width = w, .height = 1 });
            _ = line_win.printSegment(.{ .text = prefix, .style = .{ .fg = .{ .index = 8 } } }, .{});
            _ = line_win.printSegment(.{ .text = line.text, .style = .{ .fg = color } }, .{ .col_offset = 2 });
            row += 1;
        }

        // ── Input bar ──
        const input_row: u16 = h - 2;
        var input_win = win.child(.{ .x_off = 0, .y_off = @intCast(input_row), .width = w, .height = 1 });
        input_win.fill(.{ .style = .{ .bg = .{ .index = 8 } } });

        const prompt = if (self.command_mode) "/" else "> ";
        const text = if (self.command_mode) self.command_buf[0..self.command_len] else self.input_buf[0..self.input_len];
        var input_line: [4096]u8 = undefined;
        const display = std.fmt.bufPrint(&input_line, "{s}{s}", .{ prompt, text }) catch return;
        var disp_win = win.child(.{ .x_off = 0, .y_off = @intCast(input_row + 1), .width = w, .height = 1 });
        _ = disp_win.printSegment(.{ .text = display, .style = .{ .fg = .default } }, .{});
        const cx = @as(u16, @intCast(prompt.len + self.cursor_pos));
        if (cx < w) {
            _ = disp_win.printSegment(.{ .text = " ", .style = .{ .bg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } } } }, .{ .col_offset = cx });
        }

        // ── Overlays ──
        if (self.show_help) try renderHelp(self, &win, w, h);
        if (self.show_models) try renderMenu(self, &win, w, h, "Select Model", self.menu_items.items, self.menu_selected);
        if (self.show_tools) try renderMenu(self, &win, w, h, "Tools", self.menu_items.items, self.menu_selected);
        if (self.show_skills) try renderMenu(self, &win, w, h, "Skills", self.menu_items.items, self.menu_selected);
        if (self.show_config) try renderConfig(self, &win, w, h);

        try self.vx.render(self.tty.writer());
    }

    // ── Input handling ──

    pub fn handleKey(self: *App, key: vaxis.Key) void {
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) { self.quit(); return; }
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.show_help or self.show_models or self.show_tools or self.show_skills or self.show_config) {
                self.show_help = false; self.show_models = false; self.show_tools = false;
                self.show_skills = false; self.show_config = false; return;
            }
            if (self.command_mode) { self.command_mode = false; self.command_len = 0; return; }
            return;
        }
        if (self.show_models or self.show_tools or self.show_skills) { self.handleMenuNav(key); return; }
        if (self.command_mode) { self.handleCommandInput(key); return; }
        self.handleNormalInput(key);
    }

    fn handleMenuNav(self: *App, key: vaxis.Key) void {
        const n = self.menu_items.items.len;
        if (key.matches(vaxis.Key.up, .{})) { if (self.menu_selected > 0) self.menu_selected -= 1; }
        if (key.matches(vaxis.Key.down, .{})) { if (self.menu_selected < n - 1) self.menu_selected += 1; }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.menu_selected < n) {
                const sel = self.allocator.dupe(u8, self.menu_items.items[self.menu_selected]) catch return;
                self.pending_action = .{ .send_message = sel };
            }
            self.show_models = false; self.show_tools = false; self.show_skills = false;
        }
    }

    fn handleCommandInput(self: *App, key: vaxis.Key) void {
        if (key.matches(vaxis.Key.enter, .{})) {
            const cmd = self.command_buf[0..self.command_len];
            self.command_mode = false; self.command_len = 0;
            const owned = self.allocator.dupe(u8, cmd) catch return;
            self.pending_action = .{ .send_message = owned }; return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) { if (self.command_len > 0) self.command_len -= 1; return; }
        if (key.codepoint >= 0x20 and key.codepoint <= 0x7E and self.command_len < self.command_buf.len) {
            self.command_buf[self.command_len] = @intCast(key.codepoint); self.command_len += 1;
        }
    }

    fn handleNormalInput(self: *App, key: vaxis.Key) void {
        if (key.codepoint == '/' and self.input_len == 0) { self.command_mode = true; self.command_len = 0; return; }
        if (key.matches(vaxis.Key.enter, .{})) {
            const text = self.input_buf[0..self.input_len];
            if (text.len > 0) {
                self.addHistory(text) catch {};
                const owned = self.allocator.dupe(u8, text) catch return;
                self.input_len = 0; self.cursor_pos = 0;
                self.pending_action = .{ .send_message = owned };
            }
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.input_len > 0 and self.cursor_pos > 0) {
                for (self.cursor_pos - 1..self.input_len - 1) |i| self.input_buf[i] = self.input_buf[i + 1];
                self.input_len -= 1; self.cursor_pos -= 1;
            }
            return;
        }
        if (key.matches(vaxis.Key.left, .{})) { if (self.cursor_pos > 0) self.cursor_pos -= 1; return; }
        if (key.matches(vaxis.Key.right, .{})) { if (self.cursor_pos < self.input_len) self.cursor_pos += 1; return; }
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.history_idx == null and self.history.items.len > 0) { self.history_idx = self.history.items.len - 1; }
            else if (self.history_idx) |i| { if (i > 0) self.history_idx = i - 1; }
            if (self.history_idx) |i| {
                const entry = std.mem.sliceTo(&self.history.items[i], 0);
                @memcpy(self.input_buf[0..entry.len], entry);
                self.input_len = entry.len; self.cursor_pos = entry.len;
            }
            return;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (self.history_idx) |i| {
                if (i + 1 < self.history.items.len) {
                    self.history_idx = i + 1;
                    const entry = std.mem.sliceTo(&self.history.items[i + 1], 0);
                    @memcpy(self.input_buf[0..entry.len], entry); self.input_len = entry.len; self.cursor_pos = entry.len;
                } else { self.history_idx = null; self.input_len = 0; self.cursor_pos = 0; }
            }
            return;
        }
        if (key.matches(vaxis.Key.page_up, .{})) { self.scroll_offset += 10; return; }
        if (key.matches(vaxis.Key.page_down, .{})) { if (self.scroll_offset >= 10) self.scroll_offset -= 10 else self.scroll_offset = 0; return; }
        if (key.codepoint >= 0x20 and key.codepoint <= 0x7E and self.input_len < self.input_buf.len - 1) {
            var pos = self.input_len;
            while (pos > self.cursor_pos) : (pos -= 1) self.input_buf[pos] = self.input_buf[pos - 1];
            self.input_buf[self.cursor_pos] = @intCast(key.codepoint);
            self.input_len += 1; self.cursor_pos += 1;
        }
    }
};

// ── Helpers ──

pub fn shared_io() std.Io { return std.Io.Threaded.global_single_threaded.io(); }

const VisibleLine = struct { text: []const u8, role: Role };

fn wrapLines(text: []const u8, max_width: u16, lines: *std.array_list.AlignedManaged(VisibleLine, null), role: Role) !void {
    if (text.len == 0) return;
    const mw: usize = @intCast(max_width);
    var pos: usize = 0;
    while (pos < text.len) {
        var end = @min(pos + mw, text.len);
        if (end < text.len) {
            var scan = end;
            while (scan > pos and text[scan] != ' ' and text[scan] != '\n') scan -= 1;
            if (scan > pos + mw / 2) end = scan;
        }
        if (std.mem.indexOfScalar(u8, text[pos..end], '\n')) |nl| end = pos + nl;
        try lines.append(.{ .text = text[pos..end], .role = role });
        pos = end;
        if (pos < text.len and text[pos] == '\n') pos += 1;
        if (pos < text.len and text[pos] == ' ') pos += 1;
    }
}

fn boxFill(win: *const vaxis.Window, x: i17, y: i17, w: u16, h: u16) void {
    var child = win.child(.{ .x_off = x, .y_off = y, .width = w, .height = h });
    child.fill(.{ .style = .{ .bg = .{ .rgb = .{ 0x1F, 0x29, 0x37 } } } });
}

fn renderHelp(_: *App, win: *const vaxis.Window, w: u16, h: u16) !void {
    const cmds = [_][]const u8{ "/help", "/model [name]", "/config", "/tools", "/skills", "/new", "/quit", "ESC: close" };
    const ow: u16 = 38;
    const oh: u16 = @intCast(cmds.len + 3);
    const ox: i17 = @intCast((w - ow) / 2);
    const oy: i17 = @intCast((h - oh) / 2);
    boxFill(win, ox, oy, ow, oh);
    var box = win.child(.{ .x_off = ox, .y_off = oy, .width = ow, .height = oh });
    _ = box.printSegment(.{ .text = "knot3bot Commands", .style = .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true } }, .{ .col_offset = 2, .row_offset = 1 });
    for (cmds, 0..) |cmd, i| {
        _ = box.printSegment(.{ .text = cmd, .style = .{ .fg = .default } }, .{ .col_offset = 2, .row_offset = @intCast(i + 3) });
    }
}

fn renderMenu(_: *App, win: *const vaxis.Window, w: u16, h: u16, title: []const u8, items: []const []const u8, selected: usize) !void {
    const ow: u16 = 40;
    const oh: u16 = @min(@as(u16, @intCast(items.len)) + 4, h - 4);
    const ox: i17 = @intCast((w - ow) / 2);
    const oy: i17 = @intCast((h - oh) / 2);
    boxFill(win, ox, oy, ow, oh);
    var box = win.child(.{ .x_off = ox, .y_off = oy, .width = ow, .height = oh });
    _ = box.printSegment(.{ .text = title, .style = .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true } }, .{ .col_offset = 2, .row_offset = 1 });
    const offset = if (selected >= oh - 4) selected - (oh - 5) else 0;
    for (items[offset..@min(items.len, offset + oh - 3)], 0..) |item, i| {
        const idx = offset + i;
        if (idx == selected)
            _ = box.printSegment(.{ .text = ">", .style = .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } } } }, .{ .col_offset = 1, .row_offset = @intCast(i + 3) });
        _ = box.printSegment(.{ .text = item, .style = if (idx == selected) .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true } else .{ .fg = .default } },
            .{ .col_offset = 3, .row_offset = @intCast(i + 3) });
    }
    _ = box.printSegment(.{ .text = "arrows:nav Enter:pick Esc:back", .style = .{ .fg = .{ .index = 8 } } }, .{ .col_offset = 2, .row_offset = oh - 2 });
}

fn renderConfig(self: *App, win: *const vaxis.Window, w: u16, h: u16) !void {
    const ow: u16 = 44;
    const oh: u16 = 9;
    const ox: i17 = @intCast((w - ow) / 2);
    const oy: i17 = @intCast((h - oh) / 2);
    boxFill(win, ox, oy, ow, oh);
    var box = win.child(.{ .x_off = ox, .y_off = oy, .width = ow, .height = oh });
    _ = box.printSegment(.{ .text = "Configuration", .style = .{ .fg = .{ .rgb = .{ 0x22, 0xD3, 0xEE } }, .bold = true } }, .{ .col_offset = 2, .row_offset = 1 });
    var buf: [128]u8 = undefined;
    const lines = [_][]const u8{
        std.fmt.bufPrint(&buf, "Provider:  {s}", .{self.provider_name}) catch "",
        std.fmt.bufPrint(&buf, "Model:     {s}", .{self.model_name}) catch "",
        std.fmt.bufPrint(&buf, "Session:   {s}", .{self.session_id}) catch "",
        std.fmt.bufPrint(&buf, "Tools:     {d}", .{self.tools_count}) catch "",
        std.fmt.bufPrint(&buf, "Tokens:    {d}P + {d}C", .{self.token_prompt, self.token_completion}) catch "",
        "ESC: close",
    };
    for (lines, 0..) |line, i| {
        _ = box.printSegment(.{ .text = line, .style = .{ .fg = .default } }, .{ .col_offset = 2, .row_offset = @intCast(i + 3) });
    }
}
