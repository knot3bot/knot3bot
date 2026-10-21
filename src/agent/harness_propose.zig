const std = @import("std");
const harness_mod = @import("harness.zig");

const restate_prompt = "restate the user goal before the final answer";
const checklist_prefix = "verify output of ";

/// Deterministic k=1 proposal. Does not call a model or read the environment.
/// `failing_tools` is produced by `ToolCallHistory.getFailingTools`; this function does not write that history.
pub fn propose(
    allocator: std.mem.Allocator,
    current: harness_mod.Harness,
    failing_tools: []const []const u8,
    available_tools: []const []const u8,
) ![]harness_mod.HarnessPatch {
    _ = current;
    if (restate_prompt.len > 200) return error.PatchTooLarge;

    const checklist_len = if (failing_tools.len == 0) 0 else checklist_prefix.len + failing_tools[0].len;
    if (checklist_len > 200) return error.PatchTooLarge;

    const patches = try allocator.alloc(harness_mod.HarnessPatch, 2);
    errdefer allocator.free(patches);

    const checklist_a = if (failing_tools.len == 0)
        try allocator.dupe(u8, "")
    else
        try allocator.print("{s}{s}", .{ checklist_prefix, failing_tools[0] });
    errdefer allocator.free(checklist_a);

    const prompt_a = try allocator.dupe(u8, "");
    errdefer allocator.free(prompt_a);
    const prompt_b = try allocator.dupe(u8, restate_prompt);
    errdefer allocator.free(prompt_b);
    const checklist_b = try allocator.dupe(u8, "");
    errdefer allocator.free(checklist_b);
    const failing_name = if (failing_tools.len == 0) "" else failing_tools[0];
    const order_a = try toolOrderDropping(allocator, available_tools, failing_name);
    errdefer freeNames(allocator, order_a);
    const order_b = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(order_b);

    patches[0] = .{
        .prompt_append = prompt_a,
        .retry_delta = 1,
        .checklist_append = checklist_a,
        .tool_order = order_a,
    };
    patches[1] = .{
        .prompt_append = prompt_b,
        .retry_delta = 0,
        .checklist_append = checklist_b,
        .tool_order = order_b,
    };
    return patches;
}

pub fn freePatches(allocator: std.mem.Allocator, patches: []harness_mod.HarnessPatch) void {
    for (patches) |patch| {
        allocator.free(patch.prompt_append);
        allocator.free(patch.checklist_append);
        freeNames(allocator, patch.tool_order);
    }
    allocator.free(patches);
}

/// Drop `failing` from `available` when at least one other tool remains and the
/// remainder is at most 16 names. A longer remainder stays empty so the patch
/// does not hide the rest of the registry. An empty result means "keep the base order".
fn toolOrderDropping(allocator: std.mem.Allocator, available: []const []const u8, failing: []const u8) ![]const []const u8 {
    if (failing.len == 0 or available.len == 0) return allocator.alloc([]const u8, 0);
    var kept: usize = 0;
    for (available) |name| {
        if (!std.mem.eql(u8, name, failing)) kept += 1;
    }
    if (kept == 0 or kept == available.len or kept > 16) return allocator.alloc([]const u8, 0);
    const names = try allocator.alloc([]const u8, kept);
    errdefer allocator.free(names);
    var filled: usize = 0;
    errdefer for (names[0..filled]) |name| allocator.free(name);
    for (available) |name| {
        if (std.mem.eql(u8, name, failing)) continue;
        names[filled] = try allocator.dupe(u8, name);
        filled += 1;
    }
    return names;
}

fn freeNames(allocator: std.mem.Allocator, names: []const []const u8) void {
    for (names) |name| allocator.free(name);
    allocator.free(names);
}

fn baseHarness() harness_mod.Harness {
    return .{
        .version = 1,
        .parent = null,
        .prompt_section = "be careful",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
}

test "propose emits two bounded patches from failing tools" {
    const patches = try propose(std.testing.allocator, baseHarness(), &.{"shell"}, &.{});
    defer freePatches(std.testing.allocator, patches);
    try std.testing.expectEqual(@as(usize, 2), patches.len);
    try std.testing.expect(patches[0].retry_delta == 1 or patches[0].retry_delta == 0 or patches[0].retry_delta == -1);
    try std.testing.expect(std.mem.find(u8, patches[0].checklist_append, "shell") != null);
    try std.testing.expect(patches[0].prompt_append.len <= 200);
}

test "propose stays valid when nothing failed" {
    const patches = try propose(std.testing.allocator, baseHarness(), &.{}, &.{});
    defer freePatches(std.testing.allocator, patches);
    try std.testing.expectEqual(@as(usize, 2), patches.len);

    var saw_idle = false;
    var saw_restate = false;
    for (patches) |patch| {
        try std.testing.expect(patch.retry_delta == -1 or patch.retry_delta == 0 or patch.retry_delta == 1);
        try std.testing.expect(patch.prompt_append.len <= 200);
        try std.testing.expect(patch.checklist_append.len <= 200);
        if (patch.retry_delta == 0 and patch.checklist_append.len == 0) saw_idle = true;
        if (std.mem.eql(u8, patch.prompt_append, "restate the user goal before the final answer")) saw_restate = true;
    }
    try std.testing.expect(saw_idle);
    try std.testing.expect(saw_restate);
}

test "propose rejects an overlong failing tool name" {
    var name: [200]u8 = undefined;
    @memset(&name, 'n');
    try std.testing.expectError(error.PatchTooLarge, propose(std.testing.allocator, baseHarness(), &.{&name}, &.{}));
}

test "propose drops the failing tool when other tools remain" {
    const patches = try propose(std.testing.allocator, baseHarness(), &.{"shell"}, &.{ "shell", "read_file" });
    defer freePatches(std.testing.allocator, patches);
    try std.testing.expectEqual(@as(usize, 1), patches[0].tool_order.len);
    try std.testing.expectEqualStrings("read_file", patches[0].tool_order[0]);
    try std.testing.expectEqual(@as(usize, 0), patches[1].tool_order.len);
}
