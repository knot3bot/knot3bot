const std = @import("std");
const harness_mod = @import("harness.zig");
const Harness = harness_mod.Harness;
const HarnessPatch = harness_mod.HarnessPatch;
const TrajectorySummary = harness_mod.TrajectorySummary;

pub const TaskExecutor = *const fn (
    allocator: std.mem.Allocator,
    harness: Harness,
    task: []const u8,
    ctx: *anyopaque,
) anyerror!TrajectorySummary;

pub const ProbeResult = struct {
    summaries: []TrajectorySummary,
};

pub fn probe(
    allocator: std.mem.Allocator,
    base: Harness,
    patches: []const HarnessPatch,
    task_tag: []const u8,
    task: []const u8,
    exec: TaskExecutor,
    ctx: *anyopaque,
) !ProbeResult {
    const summaries = try allocator.alloc(TrajectorySummary, patches.len + 1);
    errdefer allocator.free(summaries);
    var filled: usize = 0;
    errdefer {
        for (summaries[0..filled]) |summary| freeSummary(allocator, summary);
    }

    const baseline = try exec(allocator, base, task, ctx);
    summaries[0] = try ownSummary(allocator, baseline, task_tag);
    filled = 1;

    for (patches, 0..) |patch, i| {
        if (harness_mod.applyPatch(allocator, base, patch)) |next| {
            defer harness_mod.freeHarness(allocator, next);
            const summary = try exec(allocator, next, task, ctx);
            summaries[i + 1] = try ownSummary(allocator, summary, task_tag);
            filled += 1;
        } else |err| switch (err) {
            error.HarnessTooLarge => {
                summaries[i + 1] = try ownSummary(allocator, summaries[0], task_tag);
                filled += 1;
            },
            else => return err,
        }
    }

    return .{ .summaries = summaries };
}

pub fn freeProbe(allocator: std.mem.Allocator, result: ProbeResult) void {
    for (result.summaries) |summary| freeSummary(allocator, summary);
    allocator.free(result.summaries);
}

fn ownSummary(allocator: std.mem.Allocator, summary: TrajectorySummary, task_tag: []const u8) !TrajectorySummary {
    const tag = try allocator.dupe(u8, task_tag);
    errdefer allocator.free(tag);
    const final_answer = try allocator.dupe(u8, summary.final_answer);
    errdefer allocator.free(final_answer);
    const tool_names = try allocator.alloc([]const u8, summary.tool_names.len);
    errdefer allocator.free(tool_names);
    var names_filled: usize = 0;
    errdefer {
        for (tool_names[0..names_filled]) |name| allocator.free(name);
    }
    for (summary.tool_names) |name| {
        tool_names[names_filled] = try allocator.dupe(u8, name);
        names_filled += 1;
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

const ProbeBox = struct {
    calls: usize = 0,
    cache_hit: bool = false,
    saw_cache: bool = false,
    saw_baseline: bool = false,
    saw_patch_a: bool = false,
    saw_patch_b: bool = false,
    fail_at: ?usize = null,
};

fn sampleSummary(version: u32) TrajectorySummary {
    return .{
        .harness_version = version,
        .task_tag = "code",
        .final_answer = "ok",
        .tool_names = &.{},
        .tool_success = &.{},
        .error_count = 0,
    };
}

fn run(_: std.mem.Allocator, h: Harness, task: []const u8, ctx: *anyopaque) anyerror!TrajectorySummary {
    _ = task;
    const box: *ProbeBox = @ptrCast(@alignCast(ctx));
    if (box.cache_hit) {
        box.saw_cache = true;
        return error.CacheUsed;
    }
    if (box.fail_at) |n| {
        if (box.calls == n) return error.ProbeFailed;
    }
    if (box.calls == 0 and std.mem.eql(u8, h.prompt_section, "be careful") and h.version == 1) {
        box.saw_baseline = true;
    }
    if (std.mem.find(u8, h.prompt_section, " patch-a") != null) box.saw_patch_a = true;
    if (std.mem.find(u8, h.prompt_section, " patch-b") != null) box.saw_patch_b = true;
    const version = h.version;
    box.calls += 1;
    return sampleSummary(version);
}

fn baseHarness() Harness {
    return .{
        .version = 1,
        .parent = null,
        .prompt_section = "be careful",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
}

test "probe runs baseline plus two candidates and skips cache" {
    var box = ProbeBox{};
    const patches = [_]harness_mod.HarnessPatch{
        .{ .prompt_append = " patch-a", .retry_delta = 0, .checklist_append = "" },
        .{ .prompt_append = " patch-b", .retry_delta = 1, .checklist_append = "check" },
    };
    const out = try probe(std.testing.allocator, baseHarness(), &patches, "code", "fix the test", run, @ptrCast(&box));
    defer freeProbe(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 3), out.summaries.len);
    try std.testing.expectEqual(@as(usize, 3), box.calls);
    try std.testing.expect(!box.saw_cache);
    try std.testing.expect(box.saw_baseline);
    try std.testing.expect(box.saw_patch_a);
    try std.testing.expect(box.saw_patch_b);
    try std.testing.expectEqual(@as(u32, 1), out.summaries[0].harness_version);
    try std.testing.expectEqual(@as(u32, 2), out.summaries[1].harness_version);
    try std.testing.expectEqual(@as(u32, 2), out.summaries[2].harness_version);
}

test "probe discards an oversized patch and copies the baseline summary" {
    var box = ProbeBox{};
    const baseline_prompt: [400]u8 = @splat('x');
    const overflow: [200]u8 = @splat('y');
    const base = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = &baseline_prompt,
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const patches = [_]harness_mod.HarnessPatch{
        .{ .prompt_append = &overflow, .retry_delta = 0, .checklist_append = "" },
        .{ .prompt_append = " ok", .retry_delta = 0, .checklist_append = "" },
    };
    const out = try probe(std.testing.allocator, base, &patches, "code", "fix the test", run, @ptrCast(&box));
    defer freeProbe(std.testing.allocator, out);
    try std.testing.expectEqual(@as(usize, 2), box.calls);
    try std.testing.expectEqual(@as(usize, 3), out.summaries.len);
    try std.testing.expectEqual(out.summaries[0].error_count, out.summaries[1].error_count);
}

test "probe frees summaries when the executor fails" {
    var box = ProbeBox{ .fail_at = 1 };
    const patches = [_]harness_mod.HarnessPatch{
        .{ .prompt_append = " patch-a", .retry_delta = 0, .checklist_append = "" },
        .{ .prompt_append = " patch-b", .retry_delta = 0, .checklist_append = "" },
    };
    try std.testing.expectError(error.ProbeFailed, probe(std.testing.allocator, baseHarness(), &patches, "code", "fix the test", run, @ptrCast(&box)));
}
