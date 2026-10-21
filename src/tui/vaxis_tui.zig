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
    /// Process Io. The event loop calls `Io.concurrent`, which
    /// `global_single_threaded` rejects with `ConcurrencyUnavailable`.
    io: std.Io,
    vx: vaxis.Vaxis,
    /// Lives as long as `tty`. `Tty.init` keeps this slice.
    tty_buf: [4096]u8 = undefined,
    tty: vaxis.Tty = undefined,
    tty_ready: bool = false,
    loop: vaxis.Loop(vaxis.Event) = undefined,
    loop_started: bool = false,
    resize_installed: bool = false,

    // Messages
    messages: std.ArrayList(Message),
    scroll_offset: usize = 0,

    // Input
    input_buf: [4096]u8 = @splat(0),
    input_len: usize = 0,
    cursor_pos: usize = 0,

    // Command mode
    command_mode: bool = false,
    command_buf: [256]u8 = @splat(0),
    command_len: usize = 0,

    // History
    history: std.ArrayList([4096]u8),
    history_idx: ?usize = null,

    // Status
    provider_name: []const u8 = "",
    model_name: []const u8 = "",
    session_id: []const u8 = "default",
    tools_count: usize = 0,
    token_prompt: u32 = 0,
    token_completion: u32 = 0,

    // A reply runs on a worker thread. While it does, `streaming` is true and
    // a ticker thread posts a wake every 100 ms so the spinner and the elapsed
    // clock keep moving even though no input arrives.
    streaming: bool = false,
    ticker_run: std.atomic.Value(bool) = .init(false),
    ticker: ?std.Thread = null,
    tick: std.atomic.Value(u32) = .init(0),
    wake_posted: std.atomic.Value(bool) = .init(false),

    // Overlays
    show_help: bool = false,
    show_models: bool = false,
    show_tools: bool = false,
    show_skills: bool = false,
    show_config: bool = false,
    menu_items: std.ArrayList([]const u8),
    menu_selected: usize = 0,
    help_selected: usize = 0,
    menu_title: []const u8 = "",

    // Actions
    pending_action: ?Action = null,
    should_quit: bool = false,

    pub const Action = union(enum) {
        quit,
        new_session,
        send_message: []const u8,
        set_model: []const u8,
    };

    pub fn init(allocator: std.mem.Allocator, io: std.Io, env_map: *std.process.Environ.Map) !App {
        return App{
            .allocator = allocator,
            .io = io,
            .vx = try vaxis.init(io, allocator, env_map, .{
                .system_clipboard_allocator = allocator,
                // "report all keys as escapes" stops macOS from delivering
                // IME commits. Printable text, including Han, stays UTF-8.
                .kitty_keyboard_flags = .{
                    .disambiguate = false,
                    .report_events = false,
                    .report_alternate_keys = false,
                    .report_all_as_ctl_seqs = false,
                    .report_text = false,
                },
            }),
            .messages = .empty,
            .history = .empty,
            .menu_items = .empty,
        };
    }

    pub fn deinit(self: *App) void {
        for (self.messages.items) |msg| self.allocator.free(msg.content);
        self.messages.deinit(self.allocator);
        self.history.deinit(self.allocator);
        self.menu_items.deinit(self.allocator);
    }

    pub fn start(self: *App) !void {
        // The writer buffer has to live in this object. A buffer local to init
        // is gone before the first draw.
        self.tty = try vaxis.Tty.init(self.io, &self.tty_buf);
        self.tty_ready = true;
        errdefer {
            self.tty.deinit();
            self.tty_ready = false;
        }

        self.loop = .init(self.io, &self.tty, &self.vx);
        try self.loop.start();
        self.loop_started = true;

        const writer = self.tty.writer();
        try self.vx.enterAltScreen(writer);
        if (self.tty.getWinsize()) |ws| {
            try self.vx.resize(self.allocator, writer, ws);
        } else |_| {}
        // The input thread has to be running before the capability query, or
        // the reply is never read and the screen stays 0×0.
        self.vx.queryTerminal(writer, .{ .nanoseconds = 500_000_000 }) catch {};
        self.vx.setBracketedPaste(writer, true) catch {};
        // Kitty keyboard encoding swallows macOS IME commits. Pop it even if
        // the probe thought the terminal supported it.
        if (self.vx.state.kitty_keyboard) {
            writer.writeAll("\x1b[<u") catch {};
            self.vx.state.kitty_keyboard = false;
        }
        self.vx.caps.kitty_keyboard = false;
        // Button events and the wheel only. Any-motion tracking redraws on
        // every pixel and wipes the IME preedit.
        writer.writeAll("\x1b[?1000;1006h") catch {};
        if (self.vx.screen.width == 0 or self.vx.screen.height < 3) {
            const fallback = vaxis.Winsize{ .rows = 24, .cols = 80, .x_pixel = 0, .y_pixel = 0 };
            const ws = self.tty.getWinsize() catch fallback;
            const sized = if (ws.cols == 0 or ws.rows < 3) fallback else ws;
            try self.vx.resize(self.allocator, writer, sized);
        }
        if (!self.vx.state.in_band_resize) {
            self.loop.installResizeHandler() catch {};
            self.resize_installed = true;
        }
    }

    pub fn stop(self: *App) void {
        if (!self.tty_ready) return;
        if (self.resize_installed) {
            self.loop.uninstallResizeHandler();
            self.resize_installed = false;
        }
        if (self.loop_started) {
            self.loop.stop();
            self.loop_started = false;
        }
        const writer = self.tty.writer();
        writer.writeAll("\x1b[?1000;1006l") catch {};
        self.vx.setMouseMode(writer, false) catch {};
        self.vx.exitAltScreen(writer) catch {};
        self.vx.deinit(self.allocator, writer);
        self.tty.deinit();
        self.tty_ready = false;
    }

    pub fn handleEvent(self: *App, event: vaxis.Event) !void {
        self.wake_posted.store(false, .release);
        switch (event) {
            .key_press => |key| self.handleKey(key),
            .mouse => |mouse| self.handleMouse(mouse),
            .winsize => |ws| try self.vx.resize(self.allocator, self.tty.writer(), ws),
            .paste => |text| {
                defer self.allocator.free(text);
                self.insertIntoActive(text);
            },
            else => {},
        }
    }

    pub fn clearMessages(self: *App) void {
        for (self.messages.items) |msg| self.allocator.free(msg.content);
        self.messages.clearRetainingCapacity();
        self.scroll_offset = 0;
    }

    pub fn addMessage(self: *App, role: Role, content: []const u8) !void {
        const owned = try self.allocator.dupe(u8, content);
        try self.messages.append(self.allocator, .{ .role = role, .content = owned });
        self.scroll_offset = 0;
    }

    pub fn addHistory(self: *App, cmd: []const u8) !void {
        if (cmd.len == 0 or cmd.len >= 4096) return;
        var entry: [4096]u8 = @splat(0);
        @memcpy(entry[0..cmd.len], cmd);
        try self.history.append(self.allocator, entry);
        self.history_idx = null;
    }

    pub fn takeAction(self: *App) ?Action {
        const a = self.pending_action;
        self.pending_action = null;
        return a;
    }

    pub fn quit(self: *App) void {
        self.should_quit = true;
    }

    /// Ask the input loop to draw again. Extra wakes collapse into one event
    /// so a worker cannot fill the queue and stall the keyboard.
    pub fn wake(self: *App) void {
        if (self.wake_posted.swap(true, .acq_rel)) return;
        const posted = self.loop.tryPostEvent(.focus_in) catch false;
        if (!posted) self.wake_posted.store(false, .release);
    }

    /// Mark a reply as running and start the spinner clock.
    pub fn beginBusy(self: *App) void {
        self.streaming = true;
        self.tick.store(0, .release);
        if (self.ticker != null) return;
        self.ticker_run.store(true, .release);
        self.ticker = std.Thread.spawn(.{}, tickerMain, .{self}) catch null;
        if (self.ticker == null) self.ticker_run.store(false, .release);
    }

    /// Clear the busy state and stop the ticker. Safe to call twice.
    pub fn endBusy(self: *App) void {
        self.streaming = false;
        self.ticker_run.store(false, .release);
        if (self.ticker) |t| {
            t.join();
            self.ticker = null;
        }
    }

    fn tickerMain(self: *App) void {
        while (self.ticker_run.load(.acquire)) {
            self.io.sleep(.fromMilliseconds(100), .awake) catch {};
            if (!self.ticker_run.load(.acquire)) break;
            _ = self.tick.fetchAdd(1, .acq_rel);
            self.wake();
        }
    }

    /// Render the UI in four zones: a session rail, the transcript, the
    /// composer, and the workbar. The rail drops away when the terminal is
    /// too narrow to keep the transcript readable.
    pub fn renderFrame(self: *App) !void {
        const w = self.vx.screen.width;
        const h = self.vx.screen.height;
        if (w < 16 or h < 6) return;

        // Cells keep a slice of the text they were given until the frame is
        // flushed, so every string handed to `paint` is copied into this
        // arena. It is reset here, once the previous frame has been sent.
        _ = frame_arena.reset(.retain_capacity);

        const win = self.vx.window();
        const boxed = h >= 8 and w >= 24;
        const split = w >= 76;
        const rail_w: u16 = if (split) 22 else 0;
        const chat_x: u16 = if (split) rail_w + 1 else 0;
        const pane_w: u16 = w - chat_x;
        const chat_top: u16 = 1;
        const work_row: u16 = h - 1;
        const composer_top: u16 = if (boxed) h - 4 else h - 2;
        const composer_mid: u16 = if (boxed) h - 3 else h - 2;
        const chat_bottom: u16 = composer_top;
        const area_h: usize = chat_bottom - chat_top;
        const text_width: u16 = if (pane_w > 8) pane_w - 8 else pane_w;

        var y: u16 = 0;
        while (y < h) : (y += 1) fillRow(win, y, w, oceanAt(y, h));
        if (split) self.drawRail(win, rail_w, work_row);

        const head_bg = oceanAt(0, h);
        paint(win, 0, chat_x + 1, chat_x + pane_w, "transcript", Palette.muted, head_bg, false);
        const meta = if (self.streaming)
            frameFmt("{s} {d}s", .{ spinnerFrame(self.tick.load(.acquire)), self.tick.load(.acquire) / 10 })
        else
            frameFmt("{d}+{d}", .{ self.token_prompt, self.token_completion });
        const meta_w = vaxis.gwidth.gwidth(meta, self.vx.screen.width_method);
        const meta_x = chat_x + pane_w -| meta_w -| 1;
        if (meta_x > chat_x + 12) paint(win, 0, meta_x, chat_x + pane_w, meta, if (self.streaming) Palette.cyan else Palette.muted, head_bg, self.streaming);

        var visible_lines: std.ArrayList(VisibleLine) = .empty;
        defer visible_lines.deinit(self.allocator);
        for (self.messages.items) |msg| {
            try wrapLines(self.allocator, msg.content, text_width, &visible_lines, msg.role, self.vx.screen.width_method);
        }
        if (self.streaming) {
            const ticks = self.tick.load(.acquire);
            if (visible_lines.items.len > 0) try visible_lines.append(self.allocator, .{ .text = "", .role = .assistant, .lead = false, .spacer = true });
            try visible_lines.append(self.allocator, .{
                .text = frameFmt("{s} thinking  {d}s", .{ spinnerFrame(ticks), ticks / 10 }),
                .role = .assistant,
                .lead = true,
                .live = true,
            });
        }

        const total = visible_lines.items.len;
        const max_scroll = total -| area_h;
        if (self.scroll_offset > max_scroll) self.scroll_offset = max_scroll;
        const first_line = total -| area_h -| self.scroll_offset;

        var row: u16 = chat_top;
        var line_idx: usize = first_line;
        while (row < chat_bottom and line_idx < total) : (line_idx += 1) {
            const line = visible_lines.items[line_idx];
            if (line.spacer) {
                if (row == chat_top) continue;
                row += 1;
                continue;
            }
            const bg = oceanAt(row, h);
            const label = if (!line.lead) "    " else switch (line.role) {
                .user => "you ",
                .assistant => "knot",
                .system => "sys ",
                .tool => "tool",
                .err => "err ",
            };
            const label_fg = switch (line.role) {
                .user, .assistant => Palette.cyan,
                .system, .tool => Palette.muted,
                .err => Palette.coral,
            };
            const text_fg = if (line.live) Palette.muted else switch (line.role) {
                .user => Palette.cyan,
                .assistant => Palette.ink,
                .system => Palette.amber,
                .tool => Palette.muted,
                .err => Palette.coral,
            };
            const label_x = chat_x + 1;
            const body_x = chat_x + 6;
            if (line.lead) paint(win, row, label_x, chat_x + pane_w, label, label_fg, bg, line.role == .assistant or line.role == .user);
            paint(win, row, body_x, chat_x + pane_w, line.text, text_fg, bg, false);
            row += 1;
        }

        if (self.messages.items.len <= 1 and !self.streaming and self.scroll_offset == 0 and chat_bottom > row + 5) {
            drawMark(win, chat_x, pane_w, h, row + 1, chat_bottom);
        }

        const card = Palette.card;
        const edge = if (self.streaming) Palette.line else Palette.cyan;
        const box_right = chat_x + pane_w;
        if (boxed) {
            fillBox(win, chat_x, composer_top, pane_w, 3, card);
            var top_buf: [768]u8 = undefined;
            var bot_buf: [768]u8 = undefined;
            const top_rule = rule(&top_buf, pane_w, '╭', '─', '╮');
            const bot_rule = rule(&bot_buf, pane_w, '╰', '─', '╯');
            paint(win, composer_top, chat_x, box_right, top_rule, edge, card, false);
            paint(win, composer_top + 2, chat_x, box_right, bot_rule, edge, card, false);
            if (self.streaming) paint(win, composer_top, chat_x + 2, box_right, " working ", Palette.cyan, card, true);
            paint(win, composer_mid, chat_x, box_right, "│", edge, card, false);
            paint(win, composer_mid, box_right - 1, box_right, "│", edge, card, false);
        } else {
            fillBox(win, chat_x, composer_mid, pane_w, 1, card);
        }

        const editing = if (self.command_mode) self.command_buf[0..self.command_len] else self.input_buf[0..self.input_len];
        const cursor_byte: usize = if (self.command_mode) self.command_len else self.cursor_pos;
        // ASCII prompt. U+203A is East-Asian ambiguous: this grid counts it as
        // one column, and a CJK terminal draws it as two, which lands the
        // following Han glyph under the next space.
        const prompt = if (self.command_mode) "/" else "> ";
        const text_col: u16 = chat_x + if (boxed) @as(u16, 2) else @as(u16, 1);
        const inner_w: u16 = if (boxed) pane_w -| 4 else pane_w -| 2;
        const text_limit: u16 = if (boxed) box_right -| 1 else box_right;
        var input_line: [4200]u8 = undefined;
        const shown = std.fmt.bufPrint(&input_line, "{s}{s}", .{ prompt, editing }) catch prompt;
        const cursor_in_shown = @min(shown.len, prompt.len + cursor_byte);
        const cursor_col = vaxis.gwidth.gwidth(shown[0..cursor_in_shown], self.vx.screen.width_method);
        const shown_width = vaxis.gwidth.gwidth(shown, self.vx.screen.width_method);
        const view_off: u16 = if (shown_width + 1 > inner_w and cursor_col + 1 > inner_w) cursor_col + 1 - inner_w else 0;
        var skip: usize = 0;
        var skipped_cols: u16 = 0;
        while (skip < shown.len and skipped_cols < view_off) {
            const n = std.unicode.utf8ByteSequenceLength(shown[skip]) catch break;
            if (n == 0 or skip + n > shown.len) break;
            const adv = vaxis.gwidth.gwidth(shown[skip..][0..n], self.vx.screen.width_method);
            skipped_cols += adv;
            skip += n;
        }
        paint(win, composer_mid, text_col, text_limit, shown[skip..], Palette.ink, card, false);
        if (editing.len == 0 and !self.command_mode) {
            const prompt_w = vaxis.gwidth.gwidth(prompt, self.vx.screen.width_method);
            paint(win, composer_mid, text_col + prompt_w, text_limit, "Message knot3bot", Palette.muted, card, false);
        }
        const cursor_draw = text_col + (cursor_col -| skipped_cols);
        const overlay = self.show_help or self.show_models or self.show_tools or self.show_skills or self.show_config;
        if (!overlay and cursor_draw < box_right) {
            win.setCursorShape(.beam);
            win.showCursor(cursor_draw, composer_mid);
        } else {
            win.hideCursor();
        }

        if (split) {
            var seam: u16 = 0;
            while (seam < work_row) : (seam += 1) {
                paint(win, seam, rail_w, rail_w + 1, "│", Palette.line, Palette.rail, false);
            }
        }

        fillRow(win, work_row, w, Palette.bot);
        const hint = if (self.streaming)
            "  waiting for the model · keep typing, enter sends once it answers · ctrl-c quit"
        else
            "  /help   /model   /tools   /skills   /new      enter send · pgup/pgdn scroll · ctrl-c quit";
        paint(win, work_row, 0, w, hint, Palette.muted, Palette.bot, false);

        if (self.show_help) try renderHelp(self, &win, w, h);
        if (self.show_models) try renderMenu(self, &win, w, h, "Model", self.menu_items.items, self.menu_selected);
        if (self.show_tools) try renderMenu(self, &win, w, h, "Tools", self.menu_items.items, self.menu_selected);
        if (self.show_skills) try renderMenu(self, &win, w, h, "Skills", self.menu_items.items, self.menu_selected);
        if (self.show_config) try renderConfig(self, &win, w, h);

        try self.vx.render(self.tty.writer());
    }

    fn drawRail(self: *App, win: vaxis.Window, rail_w: u16, bottom: u16) void {
        if (rail_w < 8 or bottom < 2) return;
        const bg = Palette.rail;
        fillBox(win, 0, 0, rail_w, bottom, bg);
        const limit = rail_w -| 1;
        const cols: u16 = rail_w -| 2;
        const method = self.vx.screen.width_method;
        paint(win, 0, 1, limit, "◆ knot3bot", Palette.cyan, bg, true);
        var y: u16 = if (self.streaming) blk: {
            paint(win, 1, 1, limit, frameFmt("{s} busy", .{spinnerFrame(self.tick.load(.acquire))}), Palette.cyan, bg, true);
            break :blk 2;
        } else 1;

        var tools_buf: [16]u8 = undefined;
        var tok_buf: [24]u8 = undefined;
        const tools = std.fmt.bufPrint(&tools_buf, "{d}", .{self.tools_count}) catch "0";
        const toks = std.fmt.bufPrint(&tok_buf, "{d}+{d}", .{ self.token_prompt, self.token_completion }) catch "0";
        y = railPair(win, y, bottom, limit, bg, "provider", clipCols(self.provider_name, cols, method));
        y = railPair(win, y, bottom, limit, bg, "model", clipCols(self.model_name, cols, method));
        y = railPair(win, y, bottom, limit, bg, "session", clipCols(self.session_id, cols, method));
        y = railPair(win, y, bottom, limit, bg, "tools", tools);
        y = railPair(win, y, bottom, limit, bg, "tokens", toks);
        if (y + 2 >= bottom) return;
        y += 1;
        paint(win, y, 1, limit, "commands", Palette.muted, bg, false);
        const cmds = [_][]const u8{ "/help", "/model", "/tools", "/skills", "/new", "/quit" };
        for (cmds) |cmd| {
            y += 1;
            if (y >= bottom) return;
            paint(win, y, 1, limit, cmd, Palette.cyan, bg, false);
        }
    }

    // ── Input handling ──

    pub fn handleKey(self: *App, key: vaxis.Key) void {
        if (key.matches('c', .{ .ctrl = true }) or key.matches('q', .{ .ctrl = true })) {
            self.quit();
            return;
        }
        if (key.matches(vaxis.Key.escape, .{})) {
            if (self.show_help or self.show_models or self.show_tools or self.show_skills or self.show_config) {
                self.show_help = false;
                self.show_models = false;
                self.show_tools = false;
                self.show_skills = false;
                self.show_config = false;
                return;
            }
            if (self.command_mode) {
                self.command_mode = false;
                self.command_len = 0;
                return;
            }
            return;
        }
        if (self.show_help) {
            self.handleHelpNav(key);
            return;
        }
        if (self.show_models or self.show_tools or self.show_skills) {
            self.handleMenuNav(key);
            return;
        }
        if (self.command_mode) {
            self.handleCommandInput(key);
            return;
        }
        self.handleNormalInput(key);
    }

    fn handleMouse(self: *App, mouse: vaxis.Mouse) void {
        if (mouse.type != .press) return;
        if (self.show_help or self.show_models or self.show_tools or self.show_skills or self.show_config) return;
        const h = self.vx.screen.height;
        const w = self.vx.screen.width;
        if (h < 6) return;
        const boxed = h >= 8 and w >= 24;
        const composer_top: i16 = @intCast(if (boxed) h - 4 else h - 2);
        if (mouse.row >= composer_top) return;
        switch (mouse.button) {
            .wheel_up => self.scroll_offset += 3,
            .wheel_down => self.scroll_offset -|= 3,
            else => {},
        }
    }

    fn handleHelpNav(self: *App, key: vaxis.Key) void {
        const n = help_entries.len;
        if (n == 0) return;
        if (self.help_selected >= n) self.help_selected = 0;
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.help_selected > 0) self.help_selected -= 1;
        } else if (key.matches(vaxis.Key.down, .{})) {
            if (self.help_selected + 1 < n) self.help_selected += 1;
        } else if (key.matches(vaxis.Key.enter, .{})) {
            if (self.pending_action != null) return;
            const owned = self.allocator.dupe(u8, help_entries[self.help_selected].command) catch return;
            self.pending_action = .{ .send_message = owned };
            self.show_help = false;
        }
    }

    fn handleMenuNav(self: *App, key: vaxis.Key) void {
        const n = self.menu_items.items.len;
        if (n == 0) return;
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.menu_selected > 0) self.menu_selected -= 1;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (self.menu_selected < n - 1) self.menu_selected += 1;
        }
        if (key.matches(vaxis.Key.page_up, .{})) self.menu_selected -|= 8;
        if (key.matches(vaxis.Key.page_down, .{})) self.menu_selected = @min(n - 1, self.menu_selected + 8);
        if (key.matches(vaxis.Key.home, .{})) self.menu_selected = 0;
        if (key.matches(vaxis.Key.end, .{})) self.menu_selected = n - 1;
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.show_models and self.menu_selected < n) {
                const sel = self.allocator.dupe(u8, self.menu_items.items[self.menu_selected]) catch return;
                self.pending_action = .{ .set_model = sel };
            }
            self.show_models = false;
            self.show_tools = false;
            self.show_skills = false;
        }
    }

    fn handleCommandInput(self: *App, key: vaxis.Key) void {
        if (imeText(key)) |text| {
            self.insertBytes(self.command_buf[0..], &self.command_len, self.command_len, text);
            return;
        }
        if (key.matches('u', .{ .ctrl = true })) {
            self.command_len = 0;
            return;
        }
        if (key.matches('w', .{ .ctrl = true })) {
            self.command_len = stepWordLeft(self.command_buf[0..self.command_len], self.command_len);
            return;
        }
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.pending_action != null) return;
            const cmd = self.command_buf[0..self.command_len];
            self.command_mode = false;
            self.command_len = 0;
            if (cmd.len == 0) return;
            var tmp: [257]u8 = undefined;
            tmp[0] = '/';
            const n = @min(cmd.len, tmp.len - 1);
            @memcpy(tmp[1..][0..n], cmd[0..n]);
            const owned = self.allocator.dupe(u8, tmp[0 .. n + 1]) catch return;
            self.pending_action = .{ .send_message = owned };
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.command_len == 0) {
                self.command_mode = false;
                return;
            }
            self.command_len = stepLeft(self.command_buf[0..self.command_len], self.command_len);
            return;
        }
        self.insertInto(self.command_buf[0..], &self.command_len, self.command_len, key);
    }

    fn handleNormalInput(self: *App, key: vaxis.Key) void {
        if (imeText(key)) |text| {
            self.insertBytes(self.input_buf[0..], &self.input_len, self.cursor_pos, text);
            return;
        }
        if (key.codepoint == '/' and self.input_len == 0) {
            self.command_mode = true;
            self.command_len = 0;
            return;
        }
        if (self.editLine(key)) return;
        if (key.matches(vaxis.Key.enter, .{})) {
            if (self.pending_action != null) return;
            const text = self.input_buf[0..self.input_len];
            if (text.len > 0) {
                self.addHistory(text) catch {};
                const owned = self.allocator.dupe(u8, text) catch return;
                self.input_len = 0;
                self.cursor_pos = 0;
                self.pending_action = .{ .send_message = owned };
            }
            return;
        }
        if (key.matches(vaxis.Key.backspace, .{})) {
            if (self.input_len > 0 and self.cursor_pos > 0) {
                const prev = stepLeft(self.input_buf[0..self.input_len], self.cursor_pos);
                std.mem.copyForwards(u8, self.input_buf[prev..], self.input_buf[self.cursor_pos..self.input_len]);
                self.input_len -= self.cursor_pos - prev;
                self.cursor_pos = prev;
            }
            return;
        }
        if (key.matches(vaxis.Key.left, .{})) {
            self.cursor_pos = stepLeft(self.input_buf[0..self.input_len], self.cursor_pos);
            return;
        }
        if (key.matches(vaxis.Key.right, .{})) {
            self.cursor_pos = stepRight(self.input_buf[0..self.input_len], self.cursor_pos);
            return;
        }
        if (key.matches(vaxis.Key.up, .{})) {
            if (self.history_idx == null and self.history.items.len > 0) {
                self.history_idx = self.history.items.len - 1;
            } else if (self.history_idx) |i| {
                if (i > 0) self.history_idx = i - 1;
            }
            if (self.history_idx) |i| {
                const entry = std.mem.sliceTo(&self.history.items[i], 0);
                @memcpy(self.input_buf[0..entry.len], entry);
                self.input_len = entry.len;
                self.cursor_pos = entry.len;
            }
            return;
        }
        if (key.matches(vaxis.Key.down, .{})) {
            if (self.history_idx) |i| {
                if (i + 1 < self.history.items.len) {
                    self.history_idx = i + 1;
                    const entry = std.mem.sliceTo(&self.history.items[i + 1], 0);
                    @memcpy(self.input_buf[0..entry.len], entry);
                    self.input_len = entry.len;
                    self.cursor_pos = entry.len;
                } else {
                    self.history_idx = null;
                    self.input_len = 0;
                    self.cursor_pos = 0;
                }
            }
            return;
        }
        if (key.matches(vaxis.Key.page_up, .{})) {
            self.scroll_offset += 10;
            return;
        }
        if (key.matches(vaxis.Key.page_down, .{})) {
            if (self.scroll_offset >= 10) self.scroll_offset -= 10 else self.scroll_offset = 0;
            return;
        }
        if (key.codepoint >= 0x20 and key.codepoint != 0x7F and key.codepoint < 57344) {
            self.insertInto(self.input_buf[0..], &self.input_len, self.cursor_pos, key);
            return;
        }
        if (key.text) |text| {
            if (text.len > 0 and !key.mods.ctrl) self.insertInto(self.input_buf[0..], &self.input_len, self.cursor_pos, key);
        }
    }

    fn editLine(self: *App, key: vaxis.Key) bool {
        const buf = self.input_buf[0..];
        if (key.matches(vaxis.Key.home, .{}) or key.matches('a', .{ .ctrl = true })) {
            self.cursor_pos = 0;
            return true;
        }
        if (key.matches(vaxis.Key.end, .{}) or key.matches('e', .{ .ctrl = true })) {
            self.cursor_pos = self.input_len;
            return true;
        }
        if (key.matches(vaxis.Key.delete, .{})) {
            if (self.cursor_pos < self.input_len) {
                const next = stepRight(buf[0..self.input_len], self.cursor_pos);
                std.mem.copyForwards(u8, buf[self.cursor_pos..], buf[next..self.input_len]);
                self.input_len -= next - self.cursor_pos;
            }
            return true;
        }
        if (key.matches('u', .{ .ctrl = true })) {
            if (self.cursor_pos > 0) {
                std.mem.copyForwards(u8, buf[0..], buf[self.cursor_pos..self.input_len]);
                self.input_len -= self.cursor_pos;
                self.cursor_pos = 0;
            }
            return true;
        }
        if (key.matches('k', .{ .ctrl = true })) {
            self.input_len = self.cursor_pos;
            return true;
        }
        if (key.matches('w', .{ .ctrl = true })) {
            const prev = stepWordLeft(buf[0..self.input_len], self.cursor_pos);
            std.mem.copyForwards(u8, buf[prev..], buf[self.cursor_pos..self.input_len]);
            self.input_len -= self.cursor_pos - prev;
            self.cursor_pos = prev;
            return true;
        }
        if (key.matches(vaxis.Key.left, .{ .ctrl = true })) {
            self.cursor_pos = stepWordLeft(buf[0..self.input_len], self.cursor_pos);
            return true;
        }
        if (key.matches(vaxis.Key.right, .{ .ctrl = true })) {
            self.cursor_pos = stepWordRight(buf[0..self.input_len], self.cursor_pos);
            return true;
        }
        return false;
    }

    fn insertIntoActive(self: *App, bytes: []const u8) void {
        if (self.command_mode) {
            self.insertBytes(self.command_buf[0..], &self.command_len, self.command_len, bytes);
        } else {
            self.insertBytes(self.input_buf[0..], &self.input_len, self.cursor_pos, bytes);
        }
    }

    fn insertInto(self: *App, buf: []u8, len: *usize, at: usize, key: vaxis.Key) void {
        if (key.mods.ctrl or key.mods.super) return;
        if (key.mods.alt and key.codepoint <= 0x7F) return;
        if (key.codepoint >= 57344 and key.text == null) return;
        if (key.text) |text| {
            if (text.len > 0) {
                self.insertBytes(buf, len, at, text);
                return;
            }
        }
        var encoded: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(key.codepoint, &encoded) catch return;
        self.insertBytes(buf, len, at, encoded[0..n]);
    }

    fn insertBytes(self: *App, buf: []u8, len: *usize, at: usize, bytes: []const u8) void {
        if (bytes.len == 0 or len.* + bytes.len >= buf.len) return;
        const pos = @min(at, len.*);
        std.mem.copyBackwards(u8, buf[pos + bytes.len .. len.* + bytes.len], buf[pos..len.*]);
        @memcpy(buf[pos..][0..bytes.len], bytes);
        len.* += bytes.len;
        if (!self.command_mode) self.cursor_pos = pos + bytes.len;
    }
};

/// Text produced by an input method, as opposed to the key's own ASCII.
/// A candidate confirmed with Enter arrives as Enter plus the committed
/// string; that string has to be inserted, not treated as a submit.
fn imeText(key: vaxis.Key) ?[]const u8 {
    const text = key.text orelse return null;
    if (text.len == 0 or key.mods.ctrl or key.mods.super) return null;
    if (key.codepoint > 0x7F) return text;
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(key.codepoint, &tmp) catch return text;
    if (std.mem.eql(u8, text, tmp[0..n])) return null;
    return text;
}

// ── Helpers ──

pub fn shared_io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const VisibleLine = struct {
    text: []const u8,
    role: Role,
    lead: bool,
    /// A blank row between two messages.
    spacer: bool = false,
    /// The "thinking" row shown while a reply is running.
    live: bool = false,
};

fn stepLeft(text: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var i = pos - 1;
    while (i > 0 and text[i] & 0xC0 == 0x80) i -= 1;
    return i;
}

fn stepRight(text: []const u8, pos: usize) usize {
    if (pos >= text.len) return text.len;
    const len = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
    return @min(text.len, pos + len);
}

fn isSpaceCp(text: []const u8, start: usize, end: usize) bool {
    const cp = std.unicode.utf8Decode(text[start..end]) catch return false;
    return cp == ' ' or cp == '\t';
}

fn stepWordLeft(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i > 0) {
        const prev = stepLeft(text, i);
        if (!isSpaceCp(text, prev, i)) break;
        i = prev;
    }
    while (i > 0) {
        const prev = stepLeft(text, i);
        if (isSpaceCp(text, prev, i)) break;
        i = prev;
    }
    return i;
}

fn stepWordRight(text: []const u8, pos: usize) usize {
    var i = pos;
    while (i < text.len) {
        const next = stepRight(text, i);
        if (!isSpaceCp(text, i, next)) break;
        i = next;
    }
    while (i < text.len) {
        const next = stepRight(text, i);
        if (isSpaceCp(text, i, next)) break;
        i = next;
    }
    return i;
}

fn wrapLines(allocator: std.mem.Allocator, text: []const u8, max_width: u16, lines: *std.ArrayList(VisibleLine), role: Role, method: vaxis.gwidth.Method) !void {
    if (text.len == 0 or max_width == 0) return;
    if (lines.items.len > 0) {
        try lines.append(allocator, .{ .text = "", .role = role, .lead = false, .spacer = true });
    }
    var pos: usize = 0;
    var lead = true;
    while (pos < text.len) {
        if (text[pos] == '\n') {
            pos += 1;
            continue;
        }
        var end = pos;
        var width: u16 = 0;
        var break_at = pos;
        while (end < text.len and text[end] != '\n') {
            const n = std.unicode.utf8ByteSequenceLength(text[end]) catch 1;
            if (n == 0 or end + n > text.len) break;
            const adv = vaxis.gwidth.gwidth(text[end..][0..n], method);
            if (width + adv > max_width and end > pos) break;
            width += adv;
            end += n;
            if (text[end - n] == ' ') break_at = end;
        }
        var cut = end;
        if (end < text.len and text[end] != '\n' and break_at > pos and break_at - pos > (end - pos) / 2) cut = break_at;
        if (cut == pos) {
            const n = std.unicode.utf8ByteSequenceLength(text[pos]) catch 1;
            cut = @min(text.len, pos + @max(n, 1));
        }
        try lines.append(allocator, .{ .text = text[pos..cut], .role = role, .lead = lead });
        lead = false;
        pos = cut;
        if (pos < text.len and text[pos] == '\n') pos += 1;
    }
}

const HelpEntry = struct {
    label: []const u8,
    command: []const u8,
};

const help_entries = [_]HelpEntry{
    .{ .label = "/model    choose a model", .command = "/model" },
    .{ .label = "/config   provider and session", .command = "/config" },
    .{ .label = "/tools    registered tools", .command = "/tools" },
    .{ .label = "/skills   workspace skills", .command = "/skills" },
    .{ .label = "/new      start a session", .command = "/new" },
    .{ .label = "/quit     leave", .command = "/quit" },
};

fn renderHelp(self: *App, win: *const vaxis.Window, w: u16, h: u16) !void {
    const ow: u16 = 42;
    const oh: u16 = @intCast(help_entries.len + 5);
    if (w < ow or h < oh) return;
    if (self.help_selected >= help_entries.len) self.help_selected = 0;
    const box = openPanel(win, @intCast((w - ow) / 2), @intCast((h - oh) / 2), ow, oh);
    paint(box, 1, 2, ow - 1, "Commands", Palette.cyan, Palette.card, true);
    for (help_entries, 0..) |entry, i| {
        const y: u16 = @intCast(i + 3);
        const on = i == self.help_selected;
        const bg = if (on) Palette.lift else Palette.card;
        if (on) {
            var hi = box.child(.{ .x_off = 1, .y_off = @intCast(y), .width = ow -| 2, .height = 1 });
            hi.fill(.{ .style = .{ .bg = colorOf(bg) } });
        }
        paint(box, y, 2, ow - 1, if (on) ">" else " ", Palette.cyan, bg, false);
        paint(box, y, 4, ow - 1, entry.label, if (on) Palette.cyan else Palette.ink, bg, on);
    }
    paint(box, oh - 2, 2, ow - 1, "up/down move · enter run · esc back", Palette.muted, Palette.card, false);
}

fn renderMenu(_: *App, win: *const vaxis.Window, w: u16, h: u16, title: []const u8, items: []const []const u8, selected: usize) !void {
    const ow: u16 = 40;
    if (w < ow or h < 8) return;
    const item_rows: u16 = @intCast(@min(items.len, 200));
    // Leave the composer visible underneath when the terminal is tall enough.
    const max_oh: u16 = if (h > 16) h - 8 else h - 2;
    const oh: u16 = @min(item_rows + 5, max_oh);
    if (oh < 6) return;
    const box = openPanel(win, @intCast((w - ow) / 2), @intCast((h - oh) / 2), ow, oh);
    paint(box, 1, 2, ow - 1, title, Palette.cyan, Palette.card, true);
    // Rows 3 .. oh-3 hold items; row oh-2 is the hint; oh-1 is the border.
    const window: usize = oh - 5;
    const sel = @min(selected, items.len -| 1);
    const offset = if (sel >= window) sel - (window - 1) else 0;
    var pos_buf: [24]u8 = undefined;
    const pos = std.fmt.bufPrint(&pos_buf, "{d}/{d}", .{ sel + 1, items.len }) catch "";
    paint(box, 1, ow -| (@as(u16, @intCast(pos.len)) + 3), ow - 1, pos, Palette.muted, Palette.card, false);
    for (items[offset..@min(items.len, offset + window)], 0..) |item, i| {
        const idx = offset + i;
        const y: u16 = @intCast(i + 3);
        const bg = if (idx == sel) Palette.lift else Palette.card;
        if (idx == sel) {
            var hi = box.child(.{ .x_off = 1, .y_off = @intCast(y), .width = ow -| 2, .height = 1 });
            hi.fill(.{ .style = .{ .bg = colorOf(bg) } });
        }
        paint(box, y, 2, ow - 1, if (idx == sel) "▸" else " ", Palette.cyan, bg, false);
        paint(box, y, 4, ow - 1, item, if (idx == sel) Palette.cyan else Palette.ink, bg, idx == sel);
    }
    paint(box, oh - 2, 2, ow - 1, "↑↓ move · enter pick · esc back", Palette.muted, Palette.card, false);
}

fn renderConfig(self: *App, win: *const vaxis.Window, w: u16, h: u16) !void {
    const ow: u16 = 44;
    const oh: u16 = 10;
    if (w < ow or h < oh) return;
    const box = openPanel(win, @intCast((w - ow) / 2), @intCast((h - oh) / 2), ow, oh);
    paint(box, 1, 2, ow - 1, "Configuration", Palette.cyan, Palette.card, true);
    var provider_buf: [96]u8 = undefined;
    var model_buf: [96]u8 = undefined;
    var session_buf: [96]u8 = undefined;
    var tools_buf: [96]u8 = undefined;
    var token_buf: [96]u8 = undefined;
    const lines = [_][]const u8{
        std.fmt.bufPrint(&provider_buf, "Provider  {s}", .{self.provider_name}) catch "",
        std.fmt.bufPrint(&model_buf, "Model     {s}", .{self.model_name}) catch "",
        std.fmt.bufPrint(&session_buf, "Session   {s}", .{self.session_id}) catch "",
        std.fmt.bufPrint(&tools_buf, "Tools     {d}", .{self.tools_count}) catch "",
        std.fmt.bufPrint(&token_buf, "Tokens    {d} + {d}", .{ self.token_prompt, self.token_completion }) catch "",
        "esc close",
    };
    for (lines, 0..) |line, i| {
        paint(box, @intCast(i + 3), 2, ow - 1, line, if (i + 1 == lines.len) Palette.muted else Palette.ink, Palette.card, false);
    }
}

const Palette = struct {
    const top = [3]u8{ 0x10, 0x2A, 0x45 };
    const mid = [3]u8{ 0x0A, 0x1E, 0x33 };
    const bot = [3]u8{ 0x06, 0x13, 0x20 };
    const header = [3]u8{ 0x0C, 0x22, 0x38 };
    const rail = [3]u8{ 0x08, 0x1A, 0x2C };
    const card = [3]u8{ 0x12, 0x32, 0x4C };
    const lift = [3]u8{ 0x16, 0x3E, 0x58 };
    const ink = [3]u8{ 0xE7, 0xF2, 0xFA };
    const cyan = [3]u8{ 0x7E, 0xE0, 0xFF };
    const muted = [3]u8{ 0x8A, 0xA4, 0xB8 };
    const line = [3]u8{ 0x3A, 0x8F, 0xB7 };
    const coral = [3]u8{ 0xFF, 0x8A, 0x7A };
    const amber = [3]u8{ 0xF5, 0xC1, 0x6C };
};

fn colorOf(c: [3]u8) vaxis.Cell.Color {
    return .{ .rgb = c };
}

fn lerp3(a: [3]u8, b: [3]u8, t: u16, den: u16) [3]u8 {
    const d: i32 = @max(@as(i32, den), 1);
    const tt: i32 = t;
    var out: [3]u8 = undefined;
    inline for (0..3) |i| {
        const v = @as(i32, a[i]) + @divTrunc((@as(i32, b[i]) - @as(i32, a[i])) * tt, d);
        out[i] = @intCast(std.math.clamp(v, 0, 255));
    }
    return out;
}

fn oceanAt(row: u16, height: u16) [3]u8 {
    if (height <= 1) return Palette.mid;
    const half = height / 2;
    if (row <= half) return lerp3(Palette.top, Palette.mid, row, @max(half, 1));
    return lerp3(Palette.mid, Palette.bot, row - half, @max(height - half, 1));
}

fn fillRow(win: vaxis.Window, y: u16, w: u16, bg: [3]u8) void {
    fillBox(win, 0, y, w, 1, bg);
}

fn fillBox(win: vaxis.Window, x: u16, y: u16, w: u16, h: u16, bg: [3]u8) void {
    if (w == 0 or h == 0) return;
    var box = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w, .height = h });
    box.fill(.{ .style = .{ .bg = colorOf(bg) } });
}

/// Text that has to outlive the function that built it. Valid until the next
/// `renderFrame`.
var frame_arena: std.heap.ArenaAllocator = .init(std.heap.page_allocator);

fn frameText(text: []const u8) []const u8 {
    return frame_arena.allocator().dupe(u8, text) catch "";
}

fn frameFmt(comptime fmt: []const u8, args: anytype) []const u8 {
    return frame_arena.allocator().print(fmt, args) catch "";
}

const spinner_frames = [_][]const u8{ "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" };

fn spinnerFrame(tick: u32) []const u8 {
    return spinner_frames[tick % spinner_frames.len];
}

fn paint(win: vaxis.Window, y: u16, x: u16, w: u16, text: []const u8, fg: [3]u8, bg: [3]u8, bold: bool) void {
    if (x >= w or text.len == 0) return;
    var row = win.child(.{ .x_off = @intCast(x), .y_off = @intCast(y), .width = w - x, .height = 1 });
    _ = row.printSegment(.{
        .text = frameText(text),
        .style = .{ .fg = colorOf(fg), .bg = colorOf(bg), .bold = bold },
    }, .{ .wrap = .none });
}

fn putCp(buf: []u8, cp: u21) usize {
    var tmp: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &tmp) catch return 0;
    if (n > buf.len) return 0;
    @memcpy(buf[0..n], tmp[0..n]);
    return n;
}

fn rule(buf: []u8, cols: u16, left: u21, mid: u21, right: u21) []const u8 {
    if (cols == 0 or buf.len < 4) return buf[0..0];
    var i: usize = 0;
    i += putCp(buf[i..], if (cols == 1) mid else left);
    var c: u16 = 1;
    while (c + 1 < cols and i + 4 <= buf.len) : (c += 1) i += putCp(buf[i..], mid);
    if (cols > 1 and i + 4 <= buf.len) i += putCp(buf[i..], right);
    return buf[0..i];
}

fn openPanel(win: *const vaxis.Window, x: i17, y: i17, ow: u16, oh: u16) vaxis.Window {
    var box = win.child(.{ .x_off = x, .y_off = y, .width = ow, .height = oh });
    box.fill(.{ .style = .{ .bg = colorOf(Palette.card) } });
    var top_buf: [512]u8 = undefined;
    var bot_buf: [512]u8 = undefined;
    paint(box, 0, 0, ow, rule(&top_buf, ow, '╭', '─', '╮'), Palette.line, Palette.card, false);
    var r: u16 = 1;
    while (r + 1 < oh) : (r += 1) {
        paint(box, r, 0, ow, "│", Palette.line, Palette.card, false);
        if (ow > 1) paint(box, r, ow - 1, ow, "│", Palette.line, Palette.card, false);
    }
    if (oh > 1) paint(box, oh - 1, 0, ow, rule(&bot_buf, ow, '╰', '─', '╯'), Palette.line, Palette.card, false);
    return box;
}

fn drawMark(win: vaxis.Window, origin_x: u16, pane_w: u16, screen_h: u16, top: u16, bottom: u16) void {
    const lines = [_][]const u8{ "·", ".·◆·.", "knot3bot" };
    const n: u16 = @intCast(lines.len);
    if (bottom < top + n or pane_w == 0) return;
    const y0 = top + (bottom - top - n) / 2;
    for (lines, 0..) |line, i| {
        const lw = vaxis.gwidth.gwidth(line, .unicode);
        const x = origin_x + if (pane_w > lw) (pane_w - lw) / 2 else 0;
        const yy = y0 + @as(u16, @intCast(i));
        paint(win, yy, x, origin_x + pane_w, line, if (i == 1) Palette.cyan else Palette.muted, oceanAt(yy, screen_h), i == 2);
    }
}

fn railPair(win: vaxis.Window, y: u16, bottom: u16, limit: u16, bg: [3]u8, label: []const u8, value: []const u8) u16 {
    if (y + 2 >= bottom) return y;
    const next = y + 1;
    paint(win, next, 1, limit, label, Palette.muted, bg, false);
    paint(win, next + 1, 1, limit, value, Palette.ink, bg, false);
    return next + 1;
}

fn clipCols(text: []const u8, max_cols: u16, method: vaxis.gwidth.Method) []const u8 {
    if (max_cols == 0) return text[0..0];
    if (vaxis.gwidth.gwidth(text, method) <= max_cols) return text;
    var i: usize = 0;
    var col: u16 = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch break;
        if (n == 0 or i + n > text.len) break;
        const adv = vaxis.gwidth.gwidth(text[i..][0..n], method);
        if (col + adv > max_cols) break;
        col += adv;
        i += n;
    }
    return text[0..i];
}
