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
    /// Names from the tool registry. Propose may drop the first failing tool from this list.
    available_tools: []const []const u8 = &.{},
    /// Executor calls allowed after the session starts. Below 4 there is no room for three probes plus one official run.
    call_budget: u8 = 5,
    /// Earlier harnesses searched before the in-memory baseline during rollback. Not owned by the session.
    prior_snapshots: []const Harness = &.{},
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
    // A disabled session, or a budget too small for three probes plus one official run, still executes the baseline once.
    if (!config.enable_harness_rsi or config.call_budget < 4) {
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

    const proposed = try propose_mod.propose(allocator, baseline, failing_tools, config.available_tools);
    defer propose_mod.freePatches(allocator, proposed);

    var patches = [_]HarnessPatch{ proposed[0], proposed[1] };
    if (priors.len > 0 and !harness_mod.patchContained(baseline, priors[0].patch)) patches[0] = priors[0].patch;

    const left = try applyCandidate(allocator, baseline, patches[0]);
    defer harness_mod.freeHarness(allocator, left);
    const right = try applyCandidate(allocator, baseline, patches[1]);
    defer harness_mod.freeHarness(allocator, right);

    var calls = ExecCalls{ .inner = exec, .inner_ctx = ctx };
    const probed = try probe_mod.probe(allocator, baseline, &patches, config.task_tag, task, countingExec, @ptrCast(&calls));
    defer probe_mod.freeProbe(allocator, probed);

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

    const raw = try countingExec(allocator, winner, task, @ptrCast(&calls));
    const summary = try ownSummary(allocator, raw, config.task_tag);
    errdefer freeSummary(allocator, summary);
    if (probed.summaries.len > 0 and harness_mod.prefer(probed.summaries[0], summary) == .left) {
        if (try parentSnapshot(allocator, config.prior_snapshots, baseline, winner)) |parent| {
            const reverted = try cloneHarness(allocator, parent);
            errdefer harness_mod.freeHarness(allocator, reverted);
            if (store) |s| {
                const lost = if (sameText(winner, left)) patches[0] else patches[1];
                try s.record_loss(s.ptr, config.task_tag, lost);
            }
            if (calls.calls < @as(usize, config.call_budget)) {
                const rerun = try countingExec(allocator, reverted, task, @ptrCast(&calls));
                const kept_summary = try ownSummary(allocator, rerun, config.task_tag);
                freeSummary(allocator, summary);
                harness_mod.freeHarness(allocator, winner);
                return .{ .harness = reverted, .summary = kept_summary };
            }
            harness_mod.freeHarness(allocator, winner);
            return .{ .harness = reverted, .summary = summary };
        }
    }
    return .{ .harness = winner, .summary = summary };
}

pub fn freeSession(allocator: std.mem.Allocator, out: SessionOutput) void {
    harness_mod.freeHarness(allocator, out.harness);
    freeSummary(allocator, out.summary);
}

fn sameText(a: Harness, b: Harness) bool {
    return a.max_retries == b.max_retries and std.mem.eql(u8, a.prompt_section, b.prompt_section) and std.mem.eql(u8, a.checklist, b.checklist) and sameNames(a.tool_order, b.tool_order);
}

fn sameNames(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn freePatch(allocator: std.mem.Allocator, patch: HarnessPatch) void {
    allocator.free(patch.prompt_append);
    allocator.free(patch.checklist_append);
    for (patch.tool_order) |name| allocator.free(name);
    allocator.free(patch.tool_order);
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

fn applyCandidate(allocator: std.mem.Allocator, baseline: Harness, patch: HarnessPatch) !Harness {
    if (harness_mod.applyPatch(allocator, baseline, patch)) |applied| {
        return applied;
    } else |err| switch (err) {
        error.HarnessTooLarge => return try cloneHarness(allocator, baseline),
        else => |rest| return rest,
    }
}

/// `priors`, then `baseline`, then `winner`. Frees only the temporary slice.
fn parentSnapshot(allocator: std.mem.Allocator, priors: []const Harness, baseline: Harness, winner: Harness) !?Harness {
    const snaps = try allocator.alloc(Harness, priors.len + 2);
    defer allocator.free(snaps);
    for (priors, 0..) |snap, i| snaps[i] = snap;
    snaps[priors.len] = baseline;
    snaps[priors.len + 1] = winner;
    return compose_mod.rollback(snaps, winner);
}

const ExecCalls = struct {
    calls: usize = 0,
    inner: probe_mod.TaskExecutor,
    inner_ctx: *anyopaque,
};

fn countingExec(allocator: std.mem.Allocator, harness: Harness, task: []const u8, ctx: *anyopaque) anyerror!TrajectorySummary {
    const calls: *ExecCalls = @ptrCast(@alignCast(ctx));
    calls.calls += 1;
    return calls.inner(allocator, harness, task, calls.inner_ctx);
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
    saw_stacked: bool = false,
    official_errors: ?u32 = null,
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
    if (std.mem.find(u8, h.checklist, "verify output of shellverify output of shell") != null) box.saw_stacked = true;
    if (box.calls == 4) {
        if (box.official_errors) |errors| return errorSummary(h.version, errors);
    }
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
    box.saw_shell = std.mem.find(u8, patch.checklist_append, "shell") != null;
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

test "official run worse than the baseline probe rolls back to the parent" {
    const allocator = std.testing.allocator;
    var box = Box{ .official_errors = 9 };
    const out = try runSession(allocator, .{
        .enable_harness_rsi = true,
        .task_tag = "code",
    }, baseHarness(), "fix the test", &.{"shell"}, boxStore(&box), scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expectEqual(@as(u32, 1), out.harness.version);
    try std.testing.expectEqual(@as(usize, 1), box.wins);
    try std.testing.expectEqual(@as(usize, 1), box.losses);
    try std.testing.expectEqual(@as(usize, 5), box.calls);
    try std.testing.expectEqual(@as(u32, 2), out.summary.error_count);
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

fn containedBaseline() Harness {
    return .{
        .version = 2,
        .parent = 1,
        .prompt_section = "",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "verify output of shell",
    };
}

fn lookupContained(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]StoredPatch {
    const stored = try allocator.alloc(StoredPatch, 1);
    errdefer allocator.free(stored);
    const prompt = try allocator.dupe(u8, "");
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, "verify output of shell");
    errdefer allocator.free(checklist);
    const tool_order = try allocator.alloc([]const u8, 0);
    stored[0] = .{
        .patch = .{
            .prompt_append = prompt,
            .retry_delta = 0,
            .checklist_append = checklist,
            .tool_order = tool_order,
        },
        .wins = 2,
    };
    return stored;
}

test "a prior already present in the baseline is not stacked again" {
    const allocator = std.testing.allocator;
    var box = Box{};
    const store = PatchStore{
        .ptr = &box,
        .lookup = lookupContained,
        .record_win = recordWin,
        .record_loss = recordLoss,
    };
    const out = try runSession(allocator, .{
        .enable_harness_rsi = true,
        .task_tag = "code",
    }, containedBaseline(), "fix the test", &.{"shell"}, store, scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expect(!box.saw_stacked);
    try std.testing.expectEqualStrings("verify output of shell", out.harness.checklist);
}

test "call_budget of one runs the executor once" {
    const allocator = std.testing.allocator;
    var box = Box{};
    const out = try runSession(allocator, .{
        .enable_harness_rsi = true,
        .task_tag = "code",
        .call_budget = 1,
    }, baseHarness(), "fix the test", &.{"shell"}, boxStore(&box), scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expectEqual(@as(usize, 1), box.calls);
    try std.testing.expectEqual(@as(u32, 1), out.harness.version);
}

const overflow_prompt: [400]u8 = @splat('x');

fn lookupOverflow(_: *anyopaque, allocator: std.mem.Allocator, _: []const u8) anyerror![]StoredPatch {
    const stored = try allocator.alloc(StoredPatch, 1);
    errdefer allocator.free(stored);
    const prompt = try allocator.alloc(u8, 200);
    errdefer allocator.free(prompt);
    @memset(prompt, 'y');
    const checklist = try allocator.dupe(u8, "");
    errdefer allocator.free(checklist);
    const tool_order = try allocator.alloc([]const u8, 0);
    stored[0] = .{
        .patch = .{
            .prompt_append = prompt,
            .retry_delta = 0,
            .checklist_append = checklist,
            .tool_order = tool_order,
        },
    };
    return stored;
}

test "oversized prompt append does not fail the session" {
    const allocator = std.testing.allocator;
    var box = Box{};
    const store = PatchStore{
        .ptr = &box,
        .lookup = lookupOverflow,
        .record_win = recordWin,
        .record_loss = recordLoss,
    };
    const baseline = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = &overflow_prompt,
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const out = try runSession(allocator, .{
        .enable_harness_rsi = true,
        .task_tag = "code",
    }, baseline, "fix the test", &.{}, store, scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expectEqual(@as(u32, 1), out.harness.version);
    try std.testing.expectEqual(@as(usize, 400), out.harness.prompt_section.len);
    try std.testing.expect(std.mem.find(u8, out.harness.prompt_section, "y") == null);
}

test "spent call budget reverts the harness without another exec" {
    const allocator = std.testing.allocator;
    var box = Box{ .official_errors = 9 };
    const out = try runSession(allocator, .{
        .enable_harness_rsi = true,
        .task_tag = "code",
        .call_budget = 4,
    }, baseHarness(), "fix the test", &.{"shell"}, boxStore(&box), scriptedExec, scriptedJudge, @ptrCast(&box));
    defer freeSession(allocator, out);
    try std.testing.expectEqual(@as(u32, 1), out.harness.version);
    try std.testing.expectEqual(@as(usize, 4), box.calls);
    try std.testing.expectEqual(@as(u32, 9), out.summary.error_count);
    try std.testing.expectEqual(@as(usize, 1), box.wins);
    try std.testing.expectEqual(@as(usize, 1), box.losses);
}

test "parentSnapshot finds a prior whose version is the winner parent" {
    const allocator = std.testing.allocator;
    const prior = Harness{
        .version = 2,
        .parent = null,
        .prompt_section = "old",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const baseline = Harness{
        .version = 5,
        .parent = null,
        .prompt_section = "base",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const winner = Harness{
        .version = 6,
        .parent = 2,
        .prompt_section = "new",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const found = try parentSnapshot(allocator, &.{prior}, baseline, winner);
    try std.testing.expectEqualStrings("old", found.?.prompt_section);
}
