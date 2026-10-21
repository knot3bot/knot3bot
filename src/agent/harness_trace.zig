const std = @import("std");
const harness = @import("harness.zig");

const max_answer_bytes: usize = 1024;
const max_tool_names: usize = 16;

pub const ActionNote = struct {
    name: []const u8,
    failed: bool,
};

/// Duplicate `task_tag`, a prefix of `final_answer`, and each non-empty action name.
/// `final_answer` is capped at 1024 bytes. `tool_names` keeps at most 16 names.
/// `tool_success[i]` is the inverse of the kept action's `failed` flag.
pub fn buildSummary(
    allocator: std.mem.Allocator,
    harness_version: u32,
    task_tag: []const u8,
    final_answer: []const u8,
    actions: []const ActionNote,
    error_count: u32,
) !harness.TrajectorySummary {
    const tag = try allocator.dupe(u8, task_tag);
    errdefer allocator.free(tag);

    const answer_len = @min(final_answer.len, max_answer_bytes);
    const answer = try allocator.dupe(u8, final_answer[0..answer_len]);
    errdefer allocator.free(answer);

    const kept = countKept(actions);
    const tool_names = try allocator.alloc([]const u8, kept);
    errdefer allocator.free(tool_names);
    var filled: usize = 0;
    errdefer {
        for (tool_names[0..filled]) |name| allocator.free(name);
    }

    const tool_success = try allocator.alloc(bool, kept);
    errdefer allocator.free(tool_success);

    for (actions) |action| {
        if (action.name.len == 0) continue;
        if (filled == kept) break;
        tool_names[filled] = try allocator.dupe(u8, action.name);
        tool_success[filled] = !action.failed;
        filled += 1;
    }

    return .{
        .harness_version = harness_version,
        .task_tag = tag,
        .final_answer = answer,
        .tool_names = tool_names,
        .tool_success = tool_success,
        .error_count = error_count,
    };
}

/// Frees every slice owned by `summary`, including each `tool_names` item and `tool_success`.
pub fn freeSummary(allocator: std.mem.Allocator, summary: harness.TrajectorySummary) void {
    allocator.free(summary.task_tag);
    allocator.free(summary.final_answer);
    for (summary.tool_names) |name| allocator.free(name);
    allocator.free(summary.tool_names);
    allocator.free(summary.tool_success);
}

fn countKept(actions: []const ActionNote) usize {
    var kept: usize = 0;
    for (actions) |action| {
        if (action.name.len == 0) continue;
        kept += 1;
        if (kept == max_tool_names) break;
    }
    return kept;
}

test "two actions, one failed, long answer truncated to 1024" {
    const allocator = std.testing.allocator;
    const long = try allocator.alloc(u8, 1100);
    defer allocator.free(long);
    @memset(long, 'z');

    const actions = [_]ActionNote{
        .{ .name = "shell", .failed = false },
        .{ .name = "read_file", .failed = true },
    };
    const summary = try buildSummary(allocator, 4, "code", long, &actions, 3);
    defer freeSummary(allocator, summary);

    try std.testing.expectEqual(@as(u32, 4), summary.harness_version);
    try std.testing.expectEqualStrings("code", summary.task_tag);
    try std.testing.expect(summary.task_tag.ptr != @as([*]const u8, "code"));
    try std.testing.expectEqual(@as(usize, 1024), summary.final_answer.len);
    try std.testing.expect(std.mem.eql(u8, summary.final_answer, long[0..1024]));
    try std.testing.expect(summary.final_answer.ptr != long.ptr);
    try std.testing.expectEqual(@as(usize, 2), summary.tool_names.len);
    try std.testing.expectEqual(@as(usize, 2), summary.tool_success.len);
    try std.testing.expectEqualStrings("shell", summary.tool_names[0]);
    try std.testing.expectEqualStrings("read_file", summary.tool_names[1]);
    try std.testing.expect(summary.tool_names[0].ptr != actions[0].name.ptr);
    try std.testing.expect(summary.tool_names[1].ptr != actions[1].name.ptr);
    try std.testing.expect(summary.tool_success[0]);
    try std.testing.expect(!summary.tool_success[1]);
    try std.testing.expectEqual(@as(u32, 3), summary.error_count);
}

test "empty actions yields empty tool_names" {
    const allocator = std.testing.allocator;
    const summary = try buildSummary(allocator, 1, "tag", "ok", &.{}, 0);
    defer freeSummary(allocator, summary);

    try std.testing.expectEqual(@as(usize, 0), summary.tool_names.len);
    try std.testing.expectEqual(@as(usize, 0), summary.tool_success.len);
    try std.testing.expectEqualStrings("tag", summary.task_tag);
    try std.testing.expectEqualStrings("ok", summary.final_answer);
    try std.testing.expectEqual(@as(u32, 0), summary.error_count);
}
