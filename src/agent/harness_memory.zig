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
    extern fn sqlite3_step(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_reset(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_finalize(stmt: ?*anyopaque) c_int;
    extern fn sqlite3_column_text(stmt: ?*anyopaque, iCol: c_int) ?[*:0]const u8;
    extern fn sqlite3_column_int64(stmt: ?*anyopaque, iCol: c_int) i64;
    extern fn sqlite3_free(ptr: ?*anyopaque) void;
};

const sqlite_transient: ?*anyopaque = @ptrFromInt(std.math.maxInt(usize));

const create_sql = "CREATE TABLE IF NOT EXISTS harness_patterns (task_tag TEXT NOT NULL, patch_json TEXT NOT NULL, wins INTEGER NOT NULL, losses INTEGER NOT NULL, PRIMARY KEY (task_tag, patch_json));";
const win_sql = "INSERT INTO harness_patterns(task_tag, patch_json, wins, losses) VALUES (?, ?, 1, 0) ON CONFLICT(task_tag, patch_json) DO UPDATE SET wins = wins + 1;";
const loss_sql = "INSERT INTO harness_patterns(task_tag, patch_json, wins, losses) VALUES (?, ?, 0, 1) ON CONFLICT(task_tag, patch_json) DO UPDATE SET losses = losses + 1;";
const lookup_sql = "SELECT patch_json, wins, losses FROM harness_patterns WHERE task_tag = ? AND wins > losses ORDER BY (wins - losses) DESC LIMIT 2;";

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

fn parsePatch(allocator: std.mem.Allocator, json: []const u8) !harness_mod.HarnessPatch {
    const parsed = try std.json.parseFromSlice(harness_mod.HarnessPatch, allocator, json, .{});
    defer parsed.deinit();
    const prompt = try allocator.dupe(u8, parsed.value.prompt_append);
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, parsed.value.checklist_append);
    return .{
        .prompt_append = prompt,
        .retry_delta = parsed.value.retry_delta,
        .checklist_append = checklist,
    };
}

fn freePatch(allocator: std.mem.Allocator, patch: harness_mod.HarnessPatch) void {
    allocator.free(patch.prompt_append);
    allocator.free(patch.checklist_append);
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
