const std = @import("std");
const harness_mod = @import("harness.zig");
const Harness = harness_mod.Harness;
const TrajectorySummary = harness_mod.TrajectorySummary;
const PairPreference = harness_mod.PairPreference;

pub const Judge = *const fn (
    allocator: std.mem.Allocator,
    task: []const u8,
    left: TrajectorySummary,
    right: TrajectorySummary,
    ctx: *anyopaque,
) anyerror!PairPreference;

/// `summaries[0]` is the baseline. `summaries[1]` and `summaries[2]` match `candidates`.
/// A candidate replaces the baseline only when it is the unique winner.
pub fn compose(
    allocator: std.mem.Allocator,
    task: []const u8,
    baseline: Harness,
    candidates: []const Harness,
    summaries: []const TrajectorySummary,
    judge: Judge,
    ctx: *anyopaque,
) !Harness {
    if (candidates.len != 2 or summaries.len != 3) return error.InvalidComposeInput;

    const against_first = try judge(allocator, task, summaries[0], summaries[1], ctx);
    const against_second = try judge(allocator, task, summaries[0], summaries[2], ctx);
    const first_wins = against_first == .right;
    const second_wins = against_second == .right;

    if (first_wins and second_wins) {
        const between = try judge(allocator, task, summaries[1], summaries[2], ctx);
        if (between == .left) return cloneHarness(allocator, candidates[0]);
        if (between == .right) return cloneHarness(allocator, candidates[1]);
        return cloneHarness(allocator, baseline);
    }
    if (first_wins) return cloneHarness(allocator, candidates[0]);
    if (second_wins) return cloneHarness(allocator, candidates[1]);
    return cloneHarness(allocator, baseline);
}

/// Return the snapshot whose version equals `current.parent`.
/// The result aliases `snapshots` and is not a new allocation.
pub fn rollback(snapshots: []const Harness, current: Harness) ?Harness {
    const parent = current.parent orelse return null;
    for (snapshots) |snap| {
        if (snap.version == parent) return snap;
    }
    return null;
}

fn cloneHarness(allocator: std.mem.Allocator, src: Harness) !Harness {
    const prompt = try allocator.dupe(u8, src.prompt_section);
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, src.checklist);
    errdefer allocator.free(checklist);
    const tool_order = try allocator.alloc([]const u8, src.tool_order.len);
    errdefer allocator.free(tool_order);
    var filled: usize = 0;
    errdefer {
        for (tool_order[0..filled]) |name| allocator.free(name);
    }
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

fn summary(version: u32, errors: u32) TrajectorySummary {
    return .{
        .harness_version = version,
        .task_tag = "code",
        .final_answer = "ok",
        .tool_names = &.{},
        .tool_success = &.{},
        .error_count = errors,
    };
}

fn harnessAt(version: u32, parent: ?u32, prompt: []const u8) Harness {
    return .{
        .version = version,
        .parent = parent,
        .prompt_section = prompt,
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
}

fn preferFewerErrors(_: std.mem.Allocator, _: []const u8, left: TrajectorySummary, right: TrajectorySummary, _: *anyopaque) anyerror!PairPreference {
    if (left.error_count < right.error_count) return .left;
    if (right.error_count < left.error_count) return .right;
    return .tie;
}

fn failingJudge(_: std.mem.Allocator, _: []const u8, _: TrajectorySummary, _: TrajectorySummary, _: *anyopaque) anyerror!PairPreference {
    return error.JudgeFailed;
}

test "compose keeps the unique candidate that beats the baseline" {
    const allocator = std.testing.allocator;
    const baseline = harnessAt(1, null, "base");
    const candidates = [_]Harness{
        harnessAt(2, 1, "candidate-a"),
        harnessAt(2, 1, "candidate-b"),
    };
    const summaries = [_]TrajectorySummary{
        summary(1, 2),
        summary(2, 0),
        summary(2, 1),
    };
    const winner = try compose(allocator, "fix the test", baseline, &candidates, &summaries, preferFewerErrors, undefined);
    defer harness_mod.freeHarness(allocator, winner);
    try std.testing.expectEqualStrings("candidate-a", winner.prompt_section);
    try std.testing.expectEqual(@as(?u32, 1), winner.parent);
    try std.testing.expectEqual(@as(u32, 2), winner.version);
}

test "compose keeps the baseline when both candidates tie" {
    const allocator = std.testing.allocator;
    const baseline = harnessAt(4, 3, "base");
    const candidates = [_]Harness{
        harnessAt(5, 4, "candidate-a"),
        harnessAt(5, 4, "candidate-b"),
    };
    const summaries = [_]TrajectorySummary{
        summary(4, 1),
        summary(5, 1),
        summary(5, 1),
    };
    const winner = try compose(allocator, "fix the test", baseline, &candidates, &summaries, preferFewerErrors, undefined);
    defer harness_mod.freeHarness(allocator, winner);
    try std.testing.expectEqualStrings("base", winner.prompt_section);
    try std.testing.expectEqual(@as(u32, 4), winner.version);
    try std.testing.expectEqual(@as(?u32, 3), winner.parent);
}

test "compose returns the judge error without allocating" {
    const allocator = std.testing.allocator;
    const baseline = harnessAt(1, null, "base");
    const candidates = [_]Harness{
        harnessAt(2, 1, "candidate-a"),
        harnessAt(2, 1, "candidate-b"),
    };
    const summaries = [_]TrajectorySummary{
        summary(1, 2),
        summary(2, 0),
        summary(2, 0),
    };
    try std.testing.expectError(error.JudgeFailed, compose(allocator, "fix the test", baseline, &candidates, &summaries, failingJudge, undefined));
}

test "rollback returns the parent snapshot" {
    const baseline = harnessAt(1, null, "base");
    const child = harnessAt(2, 1, "child");
    const snaps = [_]Harness{ baseline, child };
    const found = rollback(&snaps, child);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(@as(u32, 1), found.?.version);
    try std.testing.expectEqualStrings("base", found.?.prompt_section);
    try std.testing.expect(rollback(&snaps, baseline) == null);
}
