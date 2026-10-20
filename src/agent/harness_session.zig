const std = @import("std");
const harness_mod = @import("harness.zig");
const propose_mod = @import("harness_propose.zig");
const probe_mod = @import("harness_probe.zig");
const compose_mod = @import("harness_compose.zig");
const Harness = harness_mod.Harness;
const HarnessPatch = harness_mod.HarnessPatch;
const TrajectorySummary = harness_mod.TrajectorySummary;
const PairPreference = harness_mod.PairPreference;

pub const SessionConfig = struct {
    enable_harness_rsi: bool = false,
    task_tag: []const u8 = "general",
    /// Values above 1 still run a single comparison round.
    k: u8 = 1,
};

pub const StoredPatch = struct {
    patch: HarnessPatch,
    wins: i64 = 0,
    losses: i64 = 0,
};

pub const PatchStore = struct {
    ptr: *anyopaque,
    lookup: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, task_tag: []const u8) anyerror![]StoredPatch,
    record_win: *const fn (ptr: *anyopaque, task_tag: []const u8, patch: HarnessPatch) anyerror!void,
    record_loss: *const fn (ptr: *anyopaque, task_tag: []const u8, patch: HarnessPatch) anyerror!void,
};

pub const SessionOutput = struct {
    harness: Harness,
    summary: TrajectorySummary,
};

pub fn runSession(
    allocator: std.mem.Allocator,
    config: SessionConfig,
    baseline: Harness,
    task: []const u8,
    failing_tools: []const []const u8,
    store: ?PatchStore,
    exec: probe_mod.TaskExecutor,
    judge: compose_mod.Judge,
    ctx: *anyopaque,
) !SessionOutput {
    _ = config.k;
    if (!config.enable_harness_rsi) {
        const raw = try exec(allocator, baseline, task, ctx);
        const summary = try ownSummary(allocator, raw, config.task_tag);
        errdefer freeSummary(allocator, summary);
        return .{
            .harness = try cloneHarness(allocator, baseline),
            .summary = summary,
        };
    }

    var priors: []StoredPatch = &.{};
    if (store) |s| priors = try s.lookup(s.ptr, allocator, config.task_tag);
    defer if (store) |_| {
        for (priors) |item| freePatch(allocator, item.patch);
        allocator.free(priors);
    };

    const proposed = try propose_mod.propose(allocator, baseline, failing_tools);
    defer propose_mod.freePatches(allocator, proposed);

    var patches = [_]HarnessPatch{ proposed[0], proposed[1] };
    if (priors.len > 0) patches[0] = priors[0].patch;

    const probed = try probe_mod.probe(allocator, baseline, &patches, config.task_tag, task, exec, ctx);
    defer probe_mod.freeProbe(allocator, probed);

    const left = try harness_mod.applyPatch(allocator, baseline, patches[0]);
    defer harness_mod.freeHarness(allocator, left);
    const right = try harness_mod.applyPatch(allocator, baseline, patches[1]);
    defer harness_mod.freeHarness(allocator, right);
    const candidates = [_]Harness{ left, right };

    const winner = try compose_mod.compose(allocator, task, baseline, &candidates, probed.summaries, judge, ctx);
    errdefer harness_mod.freeHarness(allocator, winner);

    if (store) |s| {
        if (winner.version == baseline.version) {
            try s.record_loss(s.ptr, config.task_tag, patches[0]);
            try s.record_loss(s.ptr, config.task_tag, patches[1]);
        } else if (sameText(winner, left)) {
            try s.record_win(s.ptr, config.task_tag, patches[0]);
        } else {
            try s.record_win(s.ptr, config.task_tag, patches[1]);
        }
    }

    const raw = try exec(allocator, winner, task, ctx);
    const summary = try ownSummary(allocator, raw, config.task_tag);
    return .{ .harness = winner, .summary = summary };
}

pub fn freeSession(allocator: std.mem.Allocator, out: SessionOutput) void {
    harness_mod.freeHarness(allocator, out.harness);
    freeSummary(allocator, out.summary);
}

fn sameText(a: Harness, b: Harness) bool {
    return std.mem.eql(u8, a.prompt_section, b.prompt_section) and std.mem.eql(u8, a.checklist, b.checklist);
}

fn freePatch(allocator: std.mem.Allocator, patch: HarnessPatch) void {
    allocator.free(patch.prompt_append);
    allocator.free(patch.checklist_append);
}

fn cloneHarness(allocator: std.mem.Allocator, src: Harness) !Harness {
    const prompt = try allocator.dupe(u8, src.prompt_section);
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, src.checklist);
    errdefer allocator.free(checklist);
    const tool_order = try allocator.alloc([]const u8, src.tool_order.len);
    errdefer allocator.free(tool_order);
    var filled: usize = 0;
    errdefer for (tool_order[0..filled]) |name| allocator.free(name);
    for (src.tool_order) |name| {
        tool_order[filled] = try allocator.dupe(u8, name);
        filled += 1;
    }
    return .{
        .version = src.version,
        .parent = src.parent,
        .prompt_section = prompt,
        .tool_order = tool_order,
        .max_retries = src.max_retries,
        .checklist = checklist,
    };
}

fn ownSummary(allocator: std.mem.Allocator, summary: TrajectorySummary, task_tag: []const u8) !TrajectorySummary {
    const tag = try allocator.dupe(u8, task_tag);
    errdefer allocator.free(tag);
    const final_answer = try allocator.dupe(u8, summary.final_answer);
    errdefer allocator.free(final_answer);
    const tool_names = try allocator.alloc([]const u8, summary.tool_names.len);
    errdefer allocator.free(tool_names);
    var filled: usize = 0;
    errdefer for (tool_names[0..filled]) |name| allocator.free(name);
    for (summary.tool_names) |name| {
        tool_names[filled] = try allocator.dupe(u8, name);
        filled += 1;
    }
    const tool_success = try allocator.dupe(bool, summary.tool_success);
    return .{
        .harness_version = summary.harness_version,
        .task_tag = tag,
        .final_answer = final_answer,
        .tool_names = tool_names,
        .tool_success = tool_success,
        .error_count = summary.error_count,
    };
}

fn freeSummary(allocator: std.mem.Allocator, summary: TrajectorySummary) void {
    allocator.free(summary.task_tag);
    allocator.free(summary.final_answer);
    for (summary.tool_names) |name| allocator.free(name);
    allocator.free(summary.tool_names);
    allocator.free(summary.tool_success);
}

const Box = struct {
    calls: usize = 0,
    wins: usize = 0,
    losses: usize = 0,
    saw_shell: bool = false,
    saw_prior: bool = false,
};

fn baseHarness() Harness {
    return .{
        .version = 1,
        .parent = null,
        .prompt_section = "",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
}

fn errorSummary(version: u32, errors: u32) TrajectorySummary {
    return .{
        .harness_version = version,
        .task_tag = "code",
        .final_answer = "done",
        .tool_names = &.{},
        .tool_success = &.{},
        .error_count = errors,
    };
}

fn scriptedExec(_: std.mem.Allocator, h: Harness, _: []const u8, ctx: *anyopaque) anyerror!TrajectorySummary {
    const box: *Box = @ptrCast(@alignCast(ctx));
    box.calls += 1;
    const errors: u32 = if (h.checklist.len > 0) 0 else 2;
    return errorSummary(h.version, errors);
}

fn scriptedJudge(_: std.mem.Allocator, _: []const u8, left: TrajectorySummary, right: TrajectorySummary, _: *anyopaque) anyerror!PairPreference {
    if (left.error_count < right.error_count) return .left;
    if (right.error_count < left.error_count) return .right;
    return .tie;
}

fn lookup(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]StoredPatch {
    return try allocator.alloc(StoredPatch, 0);
}

fn recordWin(ptr: *anyopaque, _: []const u8, patch: harness_mod.HarnessPatch) anyerror!void {
    const box: *Box = @ptrCast(@alignCast(ptr));
    box.wins += 1;
    box.saw_shell = std.mem.indexOf(u8, patch.checklist_append, "shell") != null;
    box.saw_prior = std.mem.eql(u8, patch.checklist_append, "from-prior");
}

fn recordLoss(ptr: *anyopaque, _: []const u8, _: harness_mod.HarnessPatch) anyerror!void {
    const box: *Box = @ptrCast(@alignCast(ptr));
    box.losses += 1;
}

fn boxStore(box: *Box) PatchStore {
    return .{
        .ptr = box,
        .lookup = lookup,
        .record_win = recordWin,
        .record_loss = recordLoss,
    };
}

test "runSession promotes the checklist candidate and records one win" {
    const allocator = std.testing.allocator;
    var box = Box{};
    const out = try runSession(allocator, .{
        .enable_harness_rsi = true,
        .task_tag = "code",
        .k = 3,
    }, baseHarness(), "fix the test", &.{"shell"}, boxStore(&box), scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expectEqual(@as(u32, 2), out.harness.version);
    try std.testing.expect(out.harness.checklist.len > 0);
    try std.testing.expectEqual(@as(usize, 1), box.wins);
    try std.testing.expectEqual(@as(usize, 0), box.losses);
    try std.testing.expect(box.saw_shell);
    try std.testing.expectEqual(@as(usize, 4), box.calls);
}

test "disabled harness rsi runs the task once" {
    const allocator = std.testing.allocator;
    var box = Box{};
    const out = try runSession(allocator, .{
        .enable_harness_rsi = false,
        .task_tag = "code",
    }, baseHarness(), "fix the test", &.{}, boxStore(&box), scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), box.calls);
    try std.testing.expectEqual(@as(usize, 0), box.wins);
    try std.testing.expectEqual(@as(u32, 1), out.harness.version);
}
