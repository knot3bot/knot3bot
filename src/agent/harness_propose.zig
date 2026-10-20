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
        try std.fmt.allocPrint(allocator, "{s}{s}", .{ checklist_prefix, failing_tools[0] });
    errdefer allocator.free(checklist_a);

    const prompt_a = try allocator.dupe(u8, "");
    errdefer allocator.free(prompt_a);
    const prompt_b = try allocator.dupe(u8, restate_prompt);
    errdefer allocator.free(prompt_b);
    const checklist_b = try allocator.dupe(u8, "");
    errdefer allocator.free(checklist_b);

    patches[0] = .{
        .prompt_append = prompt_a,
        .retry_delta = 1,
        .checklist_append = checklist_a,
    };
    patches[1] = .{
        .prompt_append = prompt_b,
        .retry_delta = 0,
        .checklist_append = checklist_b,
    };
    return patches;
}

pub fn freePatches(allocator: std.mem.Allocator, patches: []harness_mod.HarnessPatch) void {
    for (patches) |patch| {
        allocator.free(patch.prompt_append);
        allocator.free(patch.checklist_append);
    }
    allocator.free(patches);
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
    const patches = try propose(std.testing.allocator, baseHarness(), &.{"shell"});
    defer freePatches(std.testing.allocator, patches);
    try std.testing.expectEqual(@as(usize, 2), patches.len);
    try std.testing.expect(patches[0].retry_delta == 1 or patches[0].retry_delta == 0 or patches[0].retry_delta == -1);
    try std.testing.expect(std.mem.indexOf(u8, patches[0].checklist_append, "shell") != null);
    try std.testing.expect(patches[0].prompt_append.len <= 200);
}

test "propose stays valid when nothing failed" {
    const patches = try propose(std.testing.allocator, baseHarness(), &.{});
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
    try std.testing.expectError(error.PatchTooLarge, propose(std.testing.allocator, baseHarness(), &.{&name}));
}
