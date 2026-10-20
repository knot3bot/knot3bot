//! Performance benchmarks
//! Run with: zig build benchmark
const std = @import("std");

var g_threaded: ?std.Io.Threaded = null;

/// Monotonic nanosecond timestamp for benchmark deltas.
fn nowNs() u64 {
    if (g_threaded == null) g_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    return @intCast(std.Io.Clock.Timestamp.now(g_threaded.?.io(), .awake).raw.toNanoseconds());
}

const Agent = @import("agent/agent.zig");
const root = @import("tools/root.zig");
const ToolResult = root.ToolResult;
const ToolRegistry = root.ToolRegistry;

// ============================================================================
// Agent Benchmarks
// ============================================================================

fn benchmarkTokenBudget() !void {
    var budget = Agent.TokenBudget.init(128000);
    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        budget.consume(10);
        _ = budget.hasRemaining();
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("TokenBudget: 10000 iterations in {d}ns ({d}ns/op)\n", .{
        elapsed,
        elapsed / 10000,
    });
}

fn benchmarkIterationBudget() !void {
    const start_ns = nowNs();
    var total: u64 = 0;

    // Use nested loops to avoid integer overflow
    var j: usize = 0;
    while (j < 100) : (j += 1) {
        var budget = Agent.IterationBudget.init(10000);
        var i: usize = 0;
        while (i < 10000) : (i += 1) {
            budget.tick();
            _ = budget.hasRemaining();
            _ = budget.remaining();
            total += 1;
        }
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("IterationBudget: 1000000 ops in {d}ms ({d}ns/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / total,
    });
}

fn benchmarkUsageStats() !void {
    var stats = Agent.UsageStats{};
    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        stats.update(100, 50);
        _ = stats.total_tokens;
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("UsageStats: 10000 updates in {d}ns ({d}ns/op)\n", .{
        elapsed,
        elapsed / 10000,
    });
}

fn benchmarkReActStepJSON() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const step = Agent.ReActStep{
        .step_number = 1,
        .thought = "I should perform a task",
        .action = "read_file",
        .action_input = "{\"path\":\"test.txt\"}",
        .observation = "File contains: hello world",
        .result = null,
        .duration_ms = 100,
    };

    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const json = try step.toJSON(allocator);
        allocator.free(json);
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("ReActStep.toJSON: 1000 serializations in {d}ms ({d}us/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 1000 / std.time.ns_per_us,
    });
}

// ============================================================================
// Tool Benchmarks
// ============================================================================

fn benchmarkToolResultOK() !void {
    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        const result = ToolResult.ok("Operation succeeded");
        std.debug.assert(result.success);
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("ToolResult.ok: 100000 calls in {d}ms ({d}ns/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 100000,
    });
}

fn benchmarkToolResultFail() !void {
    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 100000) : (i += 1) {
        const result = ToolResult.fail("Error message");
        std.debug.assert(!result.success);
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("ToolResult.fail: 100000 calls in {d}ms ({d}ns/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 100000,
    });
}

fn benchmarkJSONParsing() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const json_str = "{\"name\":\"test\",\"value\":42,\"enabled\":true}";
    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_str, .{});
        parsed.deinit();
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("JSON parsing: 10000 parses in {d}ms ({d}us/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 10000 / std.time.ns_per_us,
    });
}

fn benchmarkToolRegistryInit() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        var registry = try ToolRegistry.init(allocator);
        registry.deinit();
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("ToolRegistry init: 1000 allocations in {d}ms ({d}us/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 1000 / std.time.ns_per_us,
    });
}

// ============================================================================
// Memory Benchmarks
// ============================================================================

fn benchmarkStringDuplication() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const source = "This is a test string for benchmarking purposes";
    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        const dup = try allocator.dupe(u8, source);
        allocator.free(dup);
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("String duplication: 10000 in {d}ms ({d}us/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 10000 / std.time.ns_per_us,
    });
}

fn benchmarkArenaAllocation() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const start_ns = nowNs();

    var i: usize = 0;
    while (i < 10000) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(allocator);
        const alloc = arena.allocator();

        _ = try alloc.alloc(u8, 1024);
        _ = try alloc.alloc(u8, 512);
        _ = try alloc.alloc(u8, 256);

        arena.deinit();
    }

    const elapsed = nowNs() - start_ns;
    std.debug.print("Arena allocation: 10000 in {d}ms ({d}us/op)\n", .{
        elapsed / std.time.ns_per_ms,
        elapsed / 10000 / std.time.ns_per_us,
    });
}

// ============================================================================
// Main
// ============================================================================

pub fn main() !void {
    std.debug.print("\n=== Agent Benchmarks ===\n", .{});
    try benchmarkTokenBudget();
    try benchmarkIterationBudget();
    try benchmarkUsageStats();
    try benchmarkReActStepJSON();

    std.debug.print("\n=== Tool Benchmarks ===\n", .{});
    try benchmarkToolResultOK();
    try benchmarkToolResultFail();
    try benchmarkJSONParsing();
    try benchmarkToolRegistryInit();

    std.debug.print("\n=== Memory Benchmarks ===\n", .{});
    try benchmarkStringDuplication();
    try benchmarkArenaAllocation();

    std.debug.print("\n=== Benchmark Complete ===\n", .{});
}
