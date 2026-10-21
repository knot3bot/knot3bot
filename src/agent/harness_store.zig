const std = @import("std");
const harness_memory = @import("harness_memory.zig");
const harness_session = @import("harness_session.zig");

const HarnessPatch = @import("harness.zig").HarnessPatch;
const StoredPatch = harness_session.StoredPatch;

/// Adapts `memory` to the session `PatchStore` callbacks.
/// `memory` must stay alive for every later callback.
pub fn bind(memory: *harness_memory.HarnessMemory) harness_session.PatchStore {
    return .{
        .ptr = memory,
        .lookup = lookup,
        .record_win = recordWin,
        .record_loss = recordLoss,
    };
}

fn lookup(ptr: *anyopaque, allocator: std.mem.Allocator, task_tag: []const u8) anyerror![]StoredPatch {
    const memory: *harness_memory.HarnessMemory = @ptrCast(@alignCast(ptr));
    const priors = try memory.lookup(task_tag);
    defer harness_memory.HarnessMemory.freePriors(memory.allocator, priors);

    const stored = try allocator.alloc(StoredPatch, priors.len);
    var copied: usize = 0;
    errdefer {
        for (stored[0..copied]) |item| freeStoredPatch(allocator, item);
        allocator.free(stored);
    }

    for (priors) |prior| {
        stored[copied] = try copyPrior(allocator, prior);
        copied += 1;
    }
    return stored;
}

fn recordWin(ptr: *anyopaque, task_tag: []const u8, patch: HarnessPatch) anyerror!void {
    const memory: *harness_memory.HarnessMemory = @ptrCast(@alignCast(ptr));
    try memory.recordWin(task_tag, patch);
}

fn recordLoss(ptr: *anyopaque, task_tag: []const u8, patch: HarnessPatch) anyerror!void {
    const memory: *harness_memory.HarnessMemory = @ptrCast(@alignCast(ptr));
    try memory.recordLoss(task_tag, patch);
}

fn copyPrior(allocator: std.mem.Allocator, prior: harness_memory.Prior) !StoredPatch {
    const prompt = try allocator.dupe(u8, prior.patch.prompt_append);
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, prior.patch.checklist_append);
    errdefer allocator.free(checklist);
    const tool_order = try dupeNames(allocator, prior.patch.tool_order);
    return .{
        .patch = .{
            .prompt_append = prompt,
            .retry_delta = prior.patch.retry_delta,
            .checklist_append = checklist,
            .tool_order = tool_order,
        },
        .wins = prior.wins,
        .losses = prior.losses,
    };
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

fn freeStoredPatch(allocator: std.mem.Allocator, item: StoredPatch) void {
    allocator.free(item.patch.prompt_append);
    allocator.free(item.patch.checklist_append);
    for (item.patch.tool_order) |name| allocator.free(name);
    allocator.free(item.patch.tool_order);
}

test "bind records a win and lookup returns that prior" {
    const allocator = std.testing.allocator;
    var path_buf: [96]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "harness-store-{x}.db", .{@intFromPtr(&path_buf)});
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};

    var memory = try harness_memory.HarnessMemory.open(allocator, path);
    defer memory.deinit();

    const store = bind(&memory);
    const patch = HarnessPatch{
        .prompt_append = "restate the user goal before the final answer",
        .retry_delta = 0,
        .checklist_append = "",
    };
    try store.record_win(store.ptr, "code", patch);

    const found = try store.lookup(store.ptr, allocator, "code");
    defer {
        for (found) |item| freeStoredPatch(allocator, item);
        allocator.free(found);
    }
    try std.testing.expectEqual(@as(usize, 1), found.len);
    try std.testing.expectEqualStrings(patch.prompt_append, found[0].patch.prompt_append);
}
