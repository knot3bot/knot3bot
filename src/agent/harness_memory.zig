const std = @import("std");
const harness_mod = @import("harness.zig");

const sqlite_ok: c_int = 0;
const sqlite_row: c_int = 100;
const sqlite_done: c_int = 101;

const c = struct {
    extern fn sqlite3_open(filename: [*:0]const u8, ppDb: *?*anyopaque) c_int;
    extern fn sqlite3_close(db: ?*anyopaque) c_int;
    extern fn sqlite3_exec(
        db: ?*anyopaque,
        sql: [*:0]const u8,
        callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int,
        arg: ?*anyopaque,
        errmsg: *?[*c]u8,
    ) c_int;
    extern fn sqlite3_prepare_v2(db: ?*anyopaque, sql: [*:0]const u8, nByte: c_int, ppStmt: *?*anyopaque, pzTail: ?*[*c]const u8) c_int;
    extern fn sqlite3_bind_text(stmt: ?*anyopaque, index: c_int, value: [*]const u8, n: c_int, destructor: ?*anyopaque) c_int;
    extern fn sqlite3_bind_int64(stmt: ?*anyopaque, index: c_int, value: i64) c_int;
    extern fn sqlite3_step(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_reset(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_column_text(stmt: ?*anyopaque, iCol: c_int) ?[*:0]const u8;
    extern fn sqlite3_column_int64(stmt: ?*anyopaque, iCol: c_int) i64;
    extern fn sqlite3_free(ptr: ?*anyopaque) void;
};

const sqlite_transient: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

const create_sql = "CREATE TABLE IF NOT EXISTS harness_patterns (task_tag TEXT NOT NULL, patch_json TEXT NOT NULL, wins INTEGER NOT NULL, losses INTEGER NOT NULL, PRIMARY KEY (task_tag, patch_json)); CREATE TABLE IF NOT EXISTS harness_snapshots (task_tag TEXT PRIMARY KEY, harness_json TEXT NOT NULL); CREATE TABLE IF NOT EXISTS harness_failures (task_tag TEXT NOT NULL, tool_name TEXT NOT NULL, PRIMARY KEY (task_tag, tool_name)); CREATE TABLE IF NOT EXISTS harness_history (task_tag TEXT NOT NULL, version INTEGER NOT NULL, harness_json TEXT NOT NULL, PRIMARY KEY (task_tag, version));";
const win_sql = "INSERT INTO harness_patterns(task_tag, patch_json, wins, losses) VALUES (?, ?, 1, 0) ON CONFLICT(task_tag, patch_json) DO UPDATE SET wins = wins + 1;";
const loss_sql = "INSERT INTO harness_patterns(task_tag, patch_json, wins, losses) VALUES (?, ?, 0, 1) ON CONFLICT(task_tag, patch_json) DO UPDATE SET losses = losses + 1;";
const lookup_sql = "SELECT patch_json, wins, losses FROM harness_patterns WHERE task_tag = ? AND wins > losses ORDER BY (wins - losses) DESC LIMIT 2;";
const save_sql = "INSERT INTO harness_snapshots(task_tag, harness_json) VALUES (?, ?) ON CONFLICT(task_tag) DO UPDATE SET harness_json = excluded.harness_json;";
const save_history_sql = "INSERT OR REPLACE INTO harness_history(task_tag, version, harness_json) VALUES (?, ?, ?);";
const trim_history_sql = "DELETE FROM harness_history WHERE task_tag = ? AND version NOT IN (SELECT version FROM (SELECT version FROM harness_history WHERE task_tag = ? ORDER BY version DESC LIMIT 8));";
const load_sql = "SELECT harness_json FROM harness_snapshots WHERE task_tag = ?;";
const load_history_sql = "SELECT harness_json FROM harness_history WHERE task_tag = ? ORDER BY version ASC;";
const delete_failures_sql = "DELETE FROM harness_failures WHERE task_tag = ?;";
const insert_failure_sql = "INSERT OR IGNORE INTO harness_failures(task_tag, tool_name) VALUES (?, ?);";
const load_failures_sql = "SELECT tool_name FROM harness_failures WHERE task_tag = ? ORDER BY tool_name LIMIT 16;";

pub const Prior = struct {
    patch: harness_mod.HarnessPatch,
    wins: i64,
    losses: i64,
};

pub const HarnessMemory = struct {
    allocator: std.mem.Allocator,
    db: *anyopaque,

    pub fn open(allocator: std.mem.Allocator, path: []const u8) !HarnessMemory {
        const path_z = try allocator.alloc(u8, path.len + 1);
        defer allocator.free(path_z);
        @memcpy(path_z[0..path.len], path);
        path_z[path.len] = 0;
        var db: ?*anyopaque = null;
        if (c.sqlite3_open(path_z[0..path.len :0], &db) != sqlite_ok) {
            if (db) |opened| _ = c.sqlite3_close(opened);
            return error.SqliteOpenFailed;
        }
        const memory = HarnessMemory{ .allocator = allocator, .db = db.? };
        errdefer memory.deinit();
        var err_msg: ?[*c]u8 = null;
        if (c.sqlite3_exec(memory.db, create_sql, null, null, &err_msg) != sqlite_ok) {
            if (err_msg) |msg| c.sqlite3_free(msg);
            return error.SqliteExecFailed;
        }
        return memory;
    }

    pub fn deinit(self: HarnessMemory) void {
        _ = c.sqlite3_close(self.db);
    }

    pub fn recordWin(self: *HarnessMemory, task_tag: []const u8, patch: harness_mod.HarnessPatch) !void {
        try self.bump(task_tag, patch, win_sql);
    }

    pub fn recordLoss(self: *HarnessMemory, task_tag: []const u8, patch: harness_mod.HarnessPatch) !void {
        try self.bump(task_tag, patch, loss_sql);
    }

    pub fn lookup(self: *HarnessMemory, task_tag: []const u8) ![]Prior {
        var stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, lookup_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, task_tag);

        var priors: std.ArrayList(Prior) = .empty;
        errdefer {
            for (priors.items) |prior| freePatch(self.allocator, prior.patch);
            priors.deinit(self.allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == sqlite_done) break;
            if (rc != sqlite_row) return error.SqliteStepFailed;
            const json_ptr = c.sqlite3_column_text(stmt, 0) orelse return error.SqliteColumnFailed;
            const json = std.mem.span(json_ptr);
            const patch = try parsePatch(self.allocator, json);
            priors.append(self.allocator, .{
                .patch = patch,
                .wins = c.sqlite3_column_int64(stmt, 1),
                .losses = c.sqlite3_column_int64(stmt, 2),
            }) catch |err| {
                freePatch(self.allocator, patch);
                return err;
            };
        }
        return try priors.toOwnedSlice(self.allocator);
    }

    pub fn freePriors(allocator: std.mem.Allocator, priors: []Prior) void {
        for (priors) |prior| freePatch(allocator, prior.patch);
        allocator.free(priors);
    }

    pub fn saveHarness(self: *HarnessMemory, task_tag: []const u8, harness: harness_mod.Harness) !void {
        const harness_json = try std.json.Stringify.valueAlloc(self.allocator, harness, .{});
        defer self.allocator.free(harness_json);
        try execSql(self.db, "BEGIN IMMEDIATE;");
        errdefer rollback(self.db);

        {
            var stmt: ?*anyopaque = null;
            if (c.sqlite3_prepare_v2(self.db, save_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, task_tag);
            try bindText(stmt, 2, harness_json);
            if (c.sqlite3_step(stmt) != sqlite_done) return error.SqliteStepFailed;
        }
        {
            var stmt: ?*anyopaque = null;
            if (c.sqlite3_prepare_v2(self.db, save_history_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, task_tag);
            try bindInt64(stmt, 2, harness.version);
            try bindText(stmt, 3, harness_json);
            if (c.sqlite3_step(stmt) != sqlite_done) return error.SqliteStepFailed;
        }
        {
            var stmt: ?*anyopaque = null;
            if (c.sqlite3_prepare_v2(self.db, trim_history_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
            defer _ = c.sqlite3_finalize(stmt);
            try bindText(stmt, 1, task_tag);
            try bindText(stmt, 2, task_tag);
            if (c.sqlite3_step(stmt) != sqlite_done) return error.SqliteStepFailed;
        }
        try execSql(self.db, "COMMIT;");
    }

    pub fn loadHarness(self: *HarnessMemory, task_tag: []const u8) !?harness_mod.Harness {
        var stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, load_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, task_tag);
        const rc = c.sqlite3_step(stmt);
        if (rc == sqlite_done) return null;
        if (rc != sqlite_row) return error.SqliteStepFailed;
        const json_ptr = c.sqlite3_column_text(stmt, 0) orelse return error.SqliteColumnFailed;
        return try harness_mod.loadSnapshot(self.allocator, std.mem.span(json_ptr));
    }

    pub fn loadHistory(self: *HarnessMemory, task_tag: []const u8) ![]harness_mod.Harness {
        if (task_tag.len == 0) return try self.allocator.alloc(harness_mod.Harness, 0);

        var stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, load_history_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, task_tag);

        var history: std.ArrayList(harness_mod.Harness) = .empty;
        errdefer {
            for (history.items) |item| harness_mod.freeHarness(self.allocator, item);
            history.deinit(self.allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == sqlite_done) break;
            if (rc != sqlite_row) return error.SqliteStepFailed;
            const json_ptr = c.sqlite3_column_text(stmt, 0) orelse return error.SqliteColumnFailed;
            const item = try harness_mod.loadSnapshot(self.allocator, std.mem.span(json_ptr));
            history.append(self.allocator, item) catch |err| {
                harness_mod.freeHarness(self.allocator, item);
                return err;
            };
        }
        return try history.toOwnedSlice(self.allocator);
    }

    pub fn freeHistory(allocator: std.mem.Allocator, history: []harness_mod.Harness) void {
        for (history) |item| harness_mod.freeHarness(allocator, item);
        allocator.free(history);
    }

    pub fn saveFailingTools(self: *HarnessMemory, task_tag: []const u8, names: []const []const u8) !void {
        try execSql(self.db, "BEGIN IMMEDIATE;");
        errdefer rollback(self.db);

        var delete_stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, delete_failures_sql, -1, &delete_stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(delete_stmt);
        try bindText(delete_stmt, 1, task_tag);
        if (c.sqlite3_step(delete_stmt) != sqlite_done) return error.SqliteStepFailed;

        var insert_stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, insert_failure_sql, -1, &insert_stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(insert_stmt);
        var saved: usize = 0;
        for (names) |name| {
            if (name.len == 0) continue;
            if (saved == 16) break;
            if (c.sqlite3_reset(insert_stmt) != sqlite_ok) return error.SqliteStepFailed;
            try bindText(insert_stmt, 1, task_tag);
            try bindText(insert_stmt, 2, name);
            if (c.sqlite3_step(insert_stmt) != sqlite_done) return error.SqliteStepFailed;
            saved += 1;
        }
        try execSql(self.db, "COMMIT;");
    }

    pub fn loadFailingTools(self: *HarnessMemory, task_tag: []const u8) ![][]const u8 {
        var stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, load_failures_sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, task_tag);
        var names: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (names.items) |name| self.allocator.free(name);
            names.deinit(self.allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt);
            if (rc == sqlite_done) break;
            if (rc != sqlite_row) return error.SqliteStepFailed;
            const text_ptr = c.sqlite3_column_text(stmt, 0) orelse return error.SqliteColumnFailed;
            const name = try self.allocator.dupe(u8, std.mem.span(text_ptr));
            names.append(self.allocator, name) catch |err| {
                self.allocator.free(name);
                return err;
            };
        }
        return try names.toOwnedSlice(self.allocator);
    }

    fn bump(self: *HarnessMemory, task_tag: []const u8, patch: harness_mod.HarnessPatch, sql: [*:0]const u8) !void {
        const patch_json = try std.json.Stringify.valueAlloc(self.allocator, patch, .{});
        defer self.allocator.free(patch_json);
        var stmt: ?*anyopaque = null;
        if (c.sqlite3_prepare_v2(self.db, sql, -1, &stmt, null) != sqlite_ok) return error.SqlitePrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt, 1, task_tag);
        try bindText(stmt, 2, patch_json);
        if (c.sqlite3_step(stmt) != sqlite_done) return error.SqliteStepFailed;
    }
};

fn bindText(stmt: ?*anyopaque, index: c_int, value: []const u8) !void {
    if (c.sqlite3_bind_text(stmt, index, value.ptr, @intCast(value.len), sqlite_transient) != sqlite_ok) {
        return error.SqliteBindFailed;
    }
}

fn bindInt64(stmt: ?*anyopaque, index: c_int, value: u32) !void {
    if (c.sqlite3_bind_int64(stmt, index, value) != sqlite_ok) return error.SqliteBindFailed;
}

fn execSql(db: *anyopaque, sql: [*:0]const u8) !void {
    var err_msg: ?[*c]u8 = null;
    if (c.sqlite3_exec(db, sql, null, null, &err_msg) != sqlite_ok) {
        if (err_msg) |msg| c.sqlite3_free(msg);
        return error.SqliteExecFailed;
    }
}

fn rollback(db: *anyopaque) void {
    var err_msg: ?[*c]u8 = null;
    if (c.sqlite3_exec(db, "ROLLBACK;", null, null, &err_msg) != sqlite_ok) {
        if (err_msg) |msg| c.sqlite3_free(msg);
    }
}

fn parsePatch(allocator: std.mem.Allocator, json: []const u8) !harness_mod.HarnessPatch {
    const parsed = try std.json.parseFromSlice(harness_mod.HarnessPatch, allocator, json, .{});
    defer parsed.deinit();
    const prompt = try allocator.dupe(u8, parsed.value.prompt_append);
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, parsed.value.checklist_append);
    errdefer allocator.free(checklist);
    const tool_order = try dupeNames(allocator, parsed.value.tool_order);
    return .{
        .prompt_append = prompt,
        .retry_delta = parsed.value.retry_delta,
        .checklist_append = checklist,
        .tool_order = tool_order,
    };
}

fn freePatch(allocator: std.mem.Allocator, patch: harness_mod.HarnessPatch) void {
    allocator.free(patch.prompt_append);
    allocator.free(patch.checklist_append);
    for (patch.tool_order) |name| allocator.free(name);
    allocator.free(patch.tool_order);
}

fn dupeNames(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, names.len);
    errdefer allocator.free(copy);
    var filled: usize = 0;
    errdefer for (copy[0..filled]) |name| allocator.free(name);
    for (names) |name| {
        copy[filled] = try allocator.dupe(u8, name);
        filled += 1;
    }
    return copy;
}

fn samplePatch(prompt: []const u8, delta: i8, checklist: []const u8) harness_mod.HarnessPatch {
    return .{
        .prompt_append = prompt,
        .retry_delta = delta,
        .checklist_append = checklist,
    };
}

test "lookup returns only patches that have more wins than losses" {
    const allocator = std.testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "harness-mem-{x}.db", .{@intFromPtr(&path_buf)});
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var memory = try HarnessMemory.open(allocator, path);
    defer memory.deinit();

    const winner = samplePatch("restate the user goal before the final answer", 0, "");
    try memory.recordWin("code", winner);
    try memory.recordWin("code", winner);

    const found = try memory.lookup("code");
    defer HarnessMemory.freePriors(allocator, found);
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqual(@as(i64, 2), found[0].wins);
    try std.testing.expectEqualStrings(winner.prompt_append, found[0].patch.prompt_append);
    try std.testing.expectEqual(winner.retry_delta, found[0].patch.retry_delta);

    const other = try memory.lookup("office");
    defer HarnessMemory.freePriors(allocator, other);
    try std.testing.expectEqual(@as(usize, 0), other.len);

    try memory.recordLoss("code", samplePatch("", -1, "skip"));
    const priors = try memory.lookup("code");
    defer HarnessMemory.freePriors(allocator, priors);
    try std.testing.expectEqual(@as(usize, 1), priors.len);
    try std.testing.expectEqual(@as(i64, 2), priors[0].wins);
    try std.testing.expect(priors[0].wins > priors[0].losses);
}

test "lookup returns at most two priors ordered by win margin" {
    const allocator = std.testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "harness-mem-{x}.db", .{@intFromPtr(&path_buf)});
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var memory = try HarnessMemory.open(allocator, path);
    defer memory.deinit();

    const low = samplePatch("low", 0, "");
    const mid = samplePatch("mid", 0, "");
    const high = samplePatch("high", 1, "");
    try memory.recordWin("code", low);
    var i: usize = 0;
    while (i < 3) : (i += 1) try memory.recordWin("code", mid);
    i = 0;
    while (i < 5) : (i += 1) try memory.recordWin("code", high);

    const found = try memory.lookup("code");
    defer HarnessMemory.freePriors(allocator, found);
    try std.testing.expectEqual(@as(usize, 2), found.len);
    try std.testing.expectEqualStrings("high", found[0].patch.prompt_append);
    try std.testing.expectEqual(@as(i64, 5), found[0].wins);
    try std.testing.expectEqualStrings("mid", found[1].patch.prompt_append);
    try std.testing.expectEqual(@as(i64, 3), found[1].wins);
}

test "saved harness is loaded by task tag" {
    const allocator = std.testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "harness-snap-{x}.db", .{@intFromPtr(&path_buf)});
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var memory = try HarnessMemory.open(allocator, path);
    defer memory.deinit();

    const missing = try memory.loadHarness("code");
    try std.testing.expect(missing == null);

    const harness = harness_mod.Harness{
        .version = 4,
        .parent = 3,
        .prompt_section = "be careful",
        .tool_order = &.{"read_file"},
        .max_retries = 1,
        .checklist = "check",
    };
    try memory.saveHarness("code", harness);
    const loaded = (try memory.loadHarness("code")).?;
    defer harness_mod.freeHarness(allocator, loaded);
    try std.testing.expectEqual(@as(u32, 4), loaded.version);
    try std.testing.expectEqual(@as(?u32, 3), loaded.parent);
    try std.testing.expectEqualStrings("be careful", loaded.prompt_section);
    try std.testing.expectEqualStrings("check", loaded.checklist);
    try std.testing.expectEqual(@as(u8, 1), loaded.max_retries);
    try std.testing.expectEqual(@as(usize, 1), loaded.tool_order.len);
    try std.testing.expectEqualStrings("read_file", loaded.tool_order[0]);

    const other = try memory.loadHarness("office");
    try std.testing.expect(other == null);
}

test "history keeps older harness versions under the same tag" {
    const allocator = std.testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "harness-hist-{x}.db", .{@intFromPtr(&path_buf)});
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var memory = try HarnessMemory.open(allocator, path);
    defer memory.deinit();

    const older = harness_mod.Harness{
        .version = 1,
        .parent = null,
        .prompt_section = "first",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const latest = harness_mod.Harness{
        .version = 4,
        .parent = 1,
        .prompt_section = "later",
        .tool_order = &.{"read_file"},
        .max_retries = 1,
        .checklist = "check",
    };
    try memory.saveHarness("code", older);
    try memory.saveHarness("code", latest);

    const loaded = (try memory.loadHarness("code")).?;
    defer harness_mod.freeHarness(allocator, loaded);
    try std.testing.expectEqual(@as(u32, 4), loaded.version);

    const history = try memory.loadHistory("code");
    defer HarnessMemory.freeHistory(allocator, history);
    try std.testing.expectEqual(@as(usize, 2), history.len);
    try std.testing.expectEqual(@as(u32, 1), history[0].version);
    try std.testing.expectEqual(@as(u32, 4), history[1].version);
}

test "failing tool names are replaced for the task tag" {
    const allocator = std.testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "harness-fail-{x}.db", .{@intFromPtr(&path_buf)});
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var memory = try HarnessMemory.open(allocator, path);
    defer memory.deinit();

    try memory.saveFailingTools("code", &.{ "shell", "read_file" });
    const first = try memory.loadFailingTools("code");
    defer {
        for (first) |name| allocator.free(name);
        allocator.free(first);
    }
    try std.testing.expectEqual(@as(usize, 2), first.len);
    try std.testing.expectEqualStrings("read_file", first[0]);
    try std.testing.expectEqualStrings("shell", first[1]);

    try memory.saveFailingTools("code", &.{});
    const cleared = try memory.loadFailingTools("code");
    defer allocator.free(cleared);
    try std.testing.expectEqual(@as(usize, 0), cleared.len);
}
