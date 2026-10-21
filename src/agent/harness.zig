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
    /// Empty keeps `base.tool_order`. A non-empty list replaces it.
    tool_order: []const []const u8 = &.{},
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

/// The prompt cache key is the user query alone. A harness that changes the prompt, checklist, tools, or retries must not read or write that cache.
pub fn allowsPromptCache(harness: Harness) bool {
    return harness.prompt_section.len == 0 and harness.checklist.len == 0 and harness.tool_order.len == 0 and harness.max_retries == 0;
}

/// Fewer errors win. Equal errors are broken by fewer failed tools. Otherwise the comparison is a tie.
pub fn prefer(left: TrajectorySummary, right: TrajectorySummary) PairPreference {
    if (left.error_count < right.error_count) return .left;
    if (right.error_count < left.error_count) return .right;
    const left_failed = failedTools(left);
    const right_failed = failedTools(right);
    if (left_failed < right_failed) return .left;
    if (right_failed < left_failed) return .right;
    return .tie;
}

fn failedTools(summary: TrajectorySummary) u32 {
    var count: u32 = 0;
    for (summary.tool_success) |ok| {
        if (!ok) count += 1;
    }
    return count;
}

pub fn applyPatch(allocator: std.mem.Allocator, base: Harness, patch: HarnessPatch) !Harness {
    const prompt = try concatBounded(allocator, base.prompt_section, unseen(base.prompt_section, patch.prompt_append));
    errdefer allocator.free(prompt);
    const checklist = try concatBounded(allocator, base.checklist, unseen(base.checklist, patch.checklist_append));
    errdefer allocator.free(checklist);
    const tool_order = if (patch.tool_order.len > 0)
        try dupeNames(allocator, patch.tool_order)
    else
        try dupeNames(allocator, base.tool_order);
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

/// Empty `tool_order` allows every tool. A non-empty list allows only exact name matches.
pub fn toolAllowed(harness: Harness, tool_name: []const u8) bool {
    if (harness.tool_order.len == 0) return true;
    for (harness.tool_order) |name| {
        if (std.mem.eql(u8, name, tool_name)) return true;
    }
    return false;
}

/// True when every non-empty text or tool list in `patch` is already present on `base`.
/// A retry-only patch is not treated as already applied.
pub fn patchContained(base: Harness, patch: HarnessPatch) bool {
    if (patch.prompt_append.len == 0 and patch.checklist_append.len == 0 and patch.tool_order.len == 0) return false;
    if (patch.prompt_append.len > 0 and std.mem.find(u8, base.prompt_section, patch.prompt_append) == null) return false;
    if (patch.checklist_append.len > 0 and std.mem.find(u8, base.checklist, patch.checklist_append) == null) return false;
    if (patch.tool_order.len > 0 and !sameOrder(base.tool_order, patch.tool_order)) return false;
    return true;
}

fn sameOrder(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |left, right| {
        if (!std.mem.eql(u8, left, right)) return false;
    }
    return true;
}

fn unseen(base: []const u8, extra: []const u8) []const u8 {
    if (extra.len == 0) return extra;
    if (std.mem.find(u8, base, extra) != null) return "";
    return extra;
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
    try std.testing.expect(std.mem.find(u8, next.prompt_section, "verify tool output") != null);

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
    try std.testing.expect(std.mem.find(u8, sink.items, "\"version\"") != null);
    try std.testing.expect(std.mem.find(u8, sink.items, "\"parent\"") != null);
    try std.testing.expect(std.mem.findScalar(u8, sink.items, '\n') == null);

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

test "empty tool_order allows shell and read_file" {
    const harness = Harness{
        .version = 0,
        .parent = null,
        .prompt_section = "",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    try std.testing.expect(toolAllowed(harness, "shell"));
    try std.testing.expect(toolAllowed(harness, "read_file"));
}

test "tool_order of shell only allows shell" {
    const harness = Harness{
        .version = 0,
        .parent = null,
        .prompt_section = "",
        .tool_order = &.{"shell"},
        .max_retries = 0,
        .checklist = "",
    };
    try std.testing.expect(toolAllowed(harness, "shell"));
    try std.testing.expect(!toolAllowed(harness, "read_file"));
}

test "applyPatch replaces tool_order when the patch lists tools" {
    const base = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = "",
        .tool_order = &.{ "shell", "read_file" },
        .max_retries = 0,
        .checklist = "",
    };
    const patch = HarnessPatch{
        .prompt_append = "",
        .retry_delta = 0,
        .checklist_append = "",
        .tool_order = &.{"read_file"},
    };
    const next = try applyPatch(std.testing.allocator, base, patch);
    defer freeHarness(std.testing.allocator, next);
    try std.testing.expectEqual(@as(usize, 1), next.tool_order.len);
    try std.testing.expectEqualStrings("read_file", next.tool_order[0]);
    try std.testing.expect(next.tool_order[0].ptr != patch.tool_order[0].ptr);
}

test "patch json without tool_order keeps an empty order" {
    const parsed = try std.json.parseFromSlice(HarnessPatch, std.testing.allocator, "{\"prompt_append\":\"\",\"retry_delta\":0,\"checklist_append\":\"\"}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 0), parsed.value.tool_order.len);
}

test "applyPatch does not repeat text already in the harness" {
    const base = Harness{
        .version = 2,
        .parent = 1,
        .prompt_section = "restate the user goal before the final answer",
        .tool_order = &.{"read_file"},
        .max_retries = 1,
        .checklist = "verify output of shell",
    };
    const patch = HarnessPatch{
        .prompt_append = "restate the user goal before the final answer",
        .retry_delta = 1,
        .checklist_append = "verify output of shell",
        .tool_order = &.{"read_file"},
    };
    try std.testing.expect(patchContained(base, patch));
    const next = try applyPatch(std.testing.allocator, base, patch);
    defer freeHarness(std.testing.allocator, next);
    try std.testing.expectEqualStrings(base.prompt_section, next.prompt_section);
    try std.testing.expectEqualStrings(base.checklist, next.checklist);
    try std.testing.expectEqual(@as(u8, 2), next.max_retries);
}

test "equal errors prefer the run with fewer failed tools" {
    const failed = [_]bool{ false, true };
    const clean = [_]bool{true};
    const left = TrajectorySummary{
        .harness_version = 1,
        .task_tag = "code",
        .final_answer = "",
        .tool_names = &.{ "shell", "read_file" },
        .tool_success = &failed,
        .error_count = 1,
    };
    const right = TrajectorySummary{
        .harness_version = 2,
        .task_tag = "code",
        .final_answer = "",
        .tool_names = &.{"read_file"},
        .tool_success = &clean,
        .error_count = 1,
    };
    try std.testing.expect(prefer(left, right) == .right);
    try std.testing.expect(prefer(right, left) == .left);
    try std.testing.expect(prefer(left, left) == .tie);
}

test "prompt cache stays available only for an empty harness" {
    const empty = Harness{
        .version = 1,
        .parent = null,
        .prompt_section = "",
        .tool_order = &.{},
        .max_retries = 0,
        .checklist = "",
    };
    try std.testing.expect(allowsPromptCache(empty));
    var changed = empty;
    changed.checklist = "check";
    try std.testing.expect(!allowsPromptCache(changed));
    changed = empty;
    changed.max_retries = 1;
    try std.testing.expect(!allowsPromptCache(changed));
}
