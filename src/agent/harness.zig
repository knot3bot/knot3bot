const std = @import("std");

pub const max_text_bytes: usize = 512;

pub const Harness = struct {
    version: u32,
    parent: ?u32,
    prompt_section: []const u8, // ≤ 512 bytes
    tool_order: []const []const u8,
    max_retries: u8, // 0..2
    checklist: []const u8, // ≤ 512 bytes
};

pub const HarnessPatch = struct {
    prompt_append: []const u8, // ≤ 200 bytes; empty means unchanged
    retry_delta: i8, // -1, 0, or +1; applyPatch still clamps the sum
    checklist_append: []const u8, // ≤ 200 bytes
};

pub const TrajectorySummary = struct {
    harness_version: u32,
    task_tag: []const u8,
    final_answer: []const u8,
    tool_names: []const []const u8,
    tool_success: []const bool,
    error_count: u32,
};

pub const PairPreference = enum { left, right, tie };

pub fn applyPatch(allocator: std.mem.Allocator, base: Harness, patch: HarnessPatch) !Harness {
    const prompt = try concatBounded(allocator, base.prompt_section, patch.prompt_append);
    errdefer allocator.free(prompt);
    const checklist = try concatBounded(allocator, base.checklist, patch.checklist_append);
    errdefer allocator.free(checklist);
    const tool_order = try dupeNames(allocator, base.tool_order);
    return .{
        .version = base.version + 1,
        .parent = base.version,
        .prompt_section = prompt,
        .tool_order = tool_order,
        .max_retries = clampRetries(base.max_retries, patch.retry_delta),
        .checklist = checklist,
    };
}

pub fn freeHarness(allocator: std.mem.Allocator, harness: Harness) void {
    allocator.free(harness.prompt_section);
    allocator.free(harness.checklist);
    for (harness.tool_order) |name| allocator.free(name);
    allocator.free(harness.tool_order);
}

/// Write one JSON line containing `version` and `parent`.
pub fn saveSnapshot(allocator: std.mem.Allocator, sink: *std.ArrayList(u8), harness: Harness) !void {
    const bytes = try std.json.Stringify.valueAlloc(allocator, harness, .{});
    defer allocator.free(bytes);
    try sink.appendSlice(allocator, bytes);
}

pub fn loadSnapshot(allocator: std.mem.Allocator, bytes: []const u8) !Harness {
    const parsed = try std.json.parseFromSlice(Harness, allocator, bytes, .{});
    defer parsed.deinit();
    const prompt = try allocator.dupe(u8, parsed.value.prompt_section);
    errdefer allocator.free(prompt);
    const checklist = try allocator.dupe(u8, parsed.value.checklist);
    errdefer allocator.free(checklist);
    const tool_order = try dupeNames(allocator, parsed.value.tool_order);
    return .{
        .version = parsed.value.version,
        .parent = parsed.value.parent,
        .prompt_section = prompt,
        .tool_order = tool_order,
        .max_retries = parsed.value.max_retries,
        .checklist = checklist,
    };
}

fn concatBounded(allocator: std.mem.Allocator, base: []const u8, extra: []const u8) ![]u8 {
    if (base.len + extra.len > max_text_bytes) return error.HarnessTooLarge;
    const out = try allocator.alloc(u8, base.len + extra.len);
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..], extra);
    return out;
}

fn dupeNames(allocator: std.mem.Allocator, names: []const []const u8) ![]const []const u8 {
    const copy = try allocator.alloc([]const u8, names.len);
    errdefer allocator.free(copy);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |name| allocator.free(name);
    }
    for (names) |name| {
        copy[filled] = try allocator.dupe(u8, name);
        filled += 1;
    }
    return copy;
}

fn clampRetries(current: u8, delta: i8) u8 {
    const sum = @as(i16, current) + delta;
    if (sum <= 0) return 0;
    if (sum >= 2) return 2;
    return @intCast(sum);
}

test "applyPatch clamps retries and rejects overlong prompt" {
    const base = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = "be careful",
        .tool_order = &.{},
        .max_retries = 1,
        .checklist = "",
    };
    const patch = HarnessPatch{
        .prompt_append = " verify tool output",
        .retry_delta = 5, // 必须被夹到上限，不能变成 6
        .checklist_append = "check",
    };
    const next = try applyPatch(std.testing.allocator, base, patch);
    defer freeHarness(std.testing.allocator, next);
    try std.testing.expectEqual(@as(u32, 2), next.version);
    try std.testing.expectEqual(@as(?u32, 1), next.parent);
    try std.testing.expect(next.max_retries <= 2);
    try std.testing.expect(std.mem.indexOf(u8, next.prompt_section, "verify tool output") != null);

    const too_long = try std.testing.allocator.alloc(u8, 400);
    defer std.testing.allocator.free(too_long);
    @memset(too_long, 'x');
    const extra = try std.testing.allocator.alloc(u8, 200);
    defer std.testing.allocator.free(extra);
    @memset(extra, 'y');
    const huge = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = too_long,
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    const overflow = HarnessPatch{
        .prompt_append = extra,
        .retry_delta = 0,
        .checklist_append = "",
    };
    try std.testing.expectError(error.HarnessTooLarge, applyPatch(std.testing.allocator, huge, overflow));
}

test "snapshot roundtrip preserves parent" {
    const allocator = std.testing.allocator;
    const base = Harness{
        .version = 3,
        .parent = 2,
        .prompt_section = "be careful",
        .tool_order = &.{"shell"},
        .max_retries = 1,
        .checklist = "check",
    };
    var sink: std.ArrayList(u8) = .empty;
    defer sink.deinit(allocator);
    try saveSnapshot(allocator, &sink, base);
    try std.testing.expect(std.mem.indexOf(u8, sink.items, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, sink.items, "\"parent\"") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, sink.items, '\n') == null);

    const loaded = try loadSnapshot(allocator, sink.items);
    defer freeHarness(allocator, loaded);
    try std.testing.expectEqual(@as(u32, 3), loaded.version);
    try std.testing.expectEqual(@as(?u32, 2), loaded.parent);
    try std.testing.expectEqualStrings(base.prompt_section, loaded.prompt_section);
    try std.testing.expectEqualStrings(base.checklist, loaded.checklist);
    try std.testing.expectEqual(@as(u8, 1), loaded.max_retries);
    try std.testing.expectEqual(@as(usize, 1), loaded.tool_order.len);
    try std.testing.expectEqualStrings("shell", loaded.tool_order[0]);
}
