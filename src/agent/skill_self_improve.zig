//! Skill Self-Improvement Loop
//!
//! Implements the hermes-agent self-evolution pattern:
//! - Self-Evaluation Checkpoint every N tool calls
//! - Skill creation/update from successful task patterns
//! - Failure detection and correction suggestions
//! - Memory updates for facts and preferences
//!
//! The 4-Stage Learning Loop:
//! 1. Task Execution - Agent runs task using tools
//! 2. Self-Evaluation Checkpoint - Every N tool calls, evaluate progress
//! 3. Skill Creation/Update - Capture reusable patterns as skills
//! 4. Memory Update - Write facts/preferences to MEMORY.md/USER.md

const std = @import("std");
const root = @import("root.zig");

// Tool call pattern for detection
const ToolPattern = struct {
    name: []const u8,
    success_count: u32 = 0,
    failure_count: u32 = 0,
    total_duration_ms: u64 = 0,
    last_args: ?[]const u8 = null,
};

/// Skill improvement suggestion
pub const ImprovementSuggestion = struct {
    action: SuggestionAction,
    skill_name: ?[]const u8 = null,
    reason: []const u8,
    confidence: f32, // 0.0 to 1.0
    pattern_data: []const u8,
};

pub const SuggestionAction = enum {
    create_skill,
    patch_skill,
    update_memory,
    none,
};

/// Self-evaluation checkpoint result
pub const CheckpointResult = struct {
    should_checkpoint: bool,
    checkpoint_type: CheckpointType,
    suggestions: []ImprovementSuggestion,
};

pub const CheckpointType = enum {
    periodic,      // Every N tool calls
    task_complete, // Task finished
    failure_detected, // Tool failed repeatedly
    pattern_detected, // Successful pattern found
};

/// Tracks tool call history for pattern detection
pub const ToolCallHistory = struct {
    patterns: std.StringHashMap(ToolPattern),
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolCallHistory {
        return .{
            .patterns = std.StringHashMap(ToolPattern).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *ToolCallHistory) void {
        var it = self.patterns.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            if (entry.value_ptr.*.last_args) |args| {
                self.allocator.free(args);
            }
        }
        self.patterns.deinit();
    }

    /// Record a tool call result
    pub fn record(self: *ToolCallHistory, tool_name: []const u8, success: bool, duration_ms: u64, args: []const u8) !void {
        const name_copy = try self.allocator.dupe(u8, tool_name);
        errdefer self.allocator.free(name_copy);

        if (self.patterns.getPtr(name_copy)) |pattern| {
            if (success) {
                pattern.success_count += 1;
            } else {
                pattern.failure_count += 1;
            }
            pattern.total_duration_ms += duration_ms;
            if (pattern.last_args) |old_args| {
                self.allocator.free(old_args);
            }
            pattern.last_args = try self.allocator.dupe(u8, args);
        } else {
            var pattern = ToolPattern{
                .name = name_copy,
                .last_args = try self.allocator.dupe(u8, args),
            };
            if (success) {
                pattern.success_count = 1;
            } else {
                pattern.failure_count = 1;
            }
            pattern.total_duration_ms = duration_ms;
            try self.patterns.put(name_copy, pattern);
        }
    }

    /// Get success rate for a tool (0.0 to 1.0)
    pub fn successRate(self: *const ToolCallHistory, tool_name: []const u8) f32 {
        if (self.patterns.get(tool_name)) |pattern| {
            const total = pattern.success_count + pattern.failure_count;
            if (total == 0) return 1.0;
            return @as(f32, @floatFromInt(pattern.success_count)) / @as(f32, @floatFromInt(total));
        }
        return 1.0;
    }

    /// Get total tool call count
    pub fn totalCalls(self: *const ToolCallHistory) u32 {
        var total: u32 = 0;
        var it = self.patterns.iterator();
        while (it.next()) |entry| {
            total += entry.value_ptr.*.success_count + entry.value_ptr.*.failure_count;
        }
        return total;
    }

    /// Get failed tools with high failure rate
    pub fn getFailingTools(self: *const ToolCallHistory, min_failures: u32, min_failure_rate: f32) ![]const []const u8 {
        var failing = std.array_list.AlignedManaged([]const u8, null).init(self.allocator);
        defer failing.deinit();

        var it = self.patterns.iterator();
        while (it.next()) |entry| {
            const pattern = entry.value_ptr.*;
            if (pattern.failure_count >= min_failures) {
                const rate = @as(f32, @floatFromInt(pattern.failure_count)) /
                    @as(f32, @floatFromInt(pattern.failure_count + pattern.success_count));
                if (rate >= min_failure_rate) {
                    failing.append(entry.key_ptr.*) catch continue;
                }
            }
        }
        return failing.toOwnedSlice();
    }
};

/// Self-improvement engine
pub const SkillSelfImprove = struct {
    allocator: std.mem.Allocator,
    checkpoint_interval: u32, // Tool calls between checkpoints
    min_confidence_for_skill: f32, // Min confidence to suggest skill creation
    enable_memory_update: bool,
    enable_skill_creation: bool,

    // State
    history: ToolCallHistory,
    tool_calls_since_checkpoint: u32 = 0,
    last_checkpoint_suggestions: []ImprovementSuggestion,
    improvement_log_path: ?[]const u8,

    /// Initialize self-improvement engine
    pub fn init(allocator: std.mem.Allocator) SkillSelfImprove {
        return .{
            .allocator = allocator,
            .checkpoint_interval = 15, // hermes-agent default
            .min_confidence_for_skill = 0.7,
            .enable_memory_update = true,
            .enable_skill_creation = true,
            .history = ToolCallHistory.init(allocator),
            .last_checkpoint_suggestions = &.{},
            .improvement_log_path = null,
        };
    }

    pub fn deinit(self: *SkillSelfImprove) void {
        self.history.deinit();
        for (self.last_checkpoint_suggestions) |suggestion| {
            self.allocator.free(suggestion.reason);
            if (suggestion.skill_name) |name| self.allocator.free(name);
            self.allocator.free(suggestion.pattern_data);
        }
        self.allocator.free(self.last_checkpoint_suggestions);
        if (self.improvement_log_path) |path| self.allocator.free(path);
    }

    /// Record a tool call for pattern tracking
    pub fn recordToolCall(self: *SkillSelfImprove, tool_name: []const u8, success: bool, duration_ms: u64, args: []const u8) !void {
        self.history.record(tool_name, success, duration_ms, args) catch {
            // Log but don't fail on memory allocation errors
            std.log.warn("Failed to record tool call pattern", .{});
        };
        self.tool_calls_since_checkpoint += 1;
    }

    /// Run periodic checkpoint evaluation
    pub fn runCheckpoint(self: *SkillSelfImprove) !CheckpointResult {
        self.tool_calls_since_checkpoint = 0;

        var suggestions = std.array_list.AlignedManaged(ImprovementSuggestion, null).init(self.allocator);
        defer suggestions.deinit();

        // Check for failing tools that might need skill guidance
        const failing_tools = try self.history.getFailingTools(3, 0.5);
        defer {
            for (failing_tools) |tool_name| {
                self.allocator.free(tool_name);
            }
            self.allocator.free(failing_tools);
        }

        for (failing_tools) |tool_name| {
            if (self.history.patterns.get(tool_name)) |pattern| {
                const rate = @as(f32, @floatFromInt(pattern.failure_count)) /
                    @as(f32, @floatFromInt(pattern.failure_count + pattern.success_count));
                try suggestions.append(.{
                    .action = .update_memory,
                    .skill_name = null,
                    .reason = try std.fmt.allocPrint(self.allocator, "Tool '{s}' has {d:.0}% failure rate. Consider adding error handling guidance.", .{ tool_name, rate * 100 }),
                    .confidence = rate,
                    .pattern_data = try std.fmt.allocPrint(self.allocator, "{{\"tool\":\"{s}\",\"failures\":{d},\"successes\":{d}}}", .{ tool_name, pattern.failure_count, pattern.success_count }),
                });
            }
        }

        // Check for successful patterns that might warrant a skill
        try self.detectSuccessfulPatterns(&suggestions);

        const result = CheckpointResult{
            .should_checkpoint = suggestions.items.len > 0,
            .checkpoint_type = .periodic,
            .suggestions = try suggestions.toOwnedSlice(),
        };

        // Free old suggestions and store new
        for (self.last_checkpoint_suggestions) |s| {
            self.allocator.free(s.reason);
            if (s.skill_name) |n| self.allocator.free(n);
            self.allocator.free(s.pattern_data);
        }
        self.last_checkpoint_suggestions = result.suggestions;

        return result;
    }

    /// Detect successful patterns that could become skills
    fn detectSuccessfulPatterns(self: *SkillSelfImprove, suggestions: *std.array_list.AlignedManaged(ImprovementSuggestion, null)) !void {
        var it = self.history.patterns.iterator();
        while (it.next()) |entry| {
            const pattern = entry.value_ptr.*;

            // Skip if low success rate or too few calls
            if (pattern.success_count < 3) continue;

            const success_rate = @as(f32, @floatFromInt(pattern.success_count)) /
                @as(f32, @floatFromInt(pattern.success_count + pattern.failure_count));
            if (success_rate < 0.8) continue;

            // Check for repeated successful calls with similar args (workflow pattern)
            if (pattern.success_count >= 3 and pattern.last_args != null) {
                // This tool has been used successfully multiple times with similar args
                // Suggest creating a skill for this workflow
                const confidence = success_rate * @as(f32, @floatFromInt(@min(pattern.success_count, 10))) / 10.0;

                if (confidence >= self.min_confidence_for_skill) {
                    const skill_name = try std.fmt.allocPrint(self.allocator, "{s}-workflow", .{entry.key_ptr.*});
                    errdefer self.allocator.free(skill_name);

                    try suggestions.append(.{
                        .action = .create_skill,
                        .skill_name = skill_name,
                        .reason = try std.fmt.allocPrint(self.allocator, "Tool '{s}' used successfully {d} times - consider capturing as reusable skill", .{ entry.key_ptr.*, pattern.success_count }),
                        .confidence = confidence,
                        .pattern_data = try std.fmt.allocPrint(self.allocator, "{{\"tool\":\"{s}\",\"examples\":{d},\"avg_duration_ms\":{d}}}", .{
                            entry.key_ptr.*,
                            pattern.success_count,
                            pattern.total_duration_ms / pattern.success_count,
                        }),
                    });
                }
            }
        }
    }

    /// Run task completion evaluation - more comprehensive than periodic
    pub fn runCompletionEvaluation(self: *SkillSelfImprove) !CheckpointResult {
        self.tool_calls_since_checkpoint = 0;

        var suggestions = std.array_list.AlignedManaged(ImprovementSuggestion, null).init(self.allocator);
        defer suggestions.deinit();

        // Check for overall success patterns
        const total_calls = self.history.totalCalls();
        if (total_calls >= 5) {
            // Task with 5+ tool calls - check if it completed successfully
            var all_success = true;
            var it = self.history.patterns.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.*.failure_count > 0) {
                    all_success = false;
                    break;
                }
            }

            if (all_success and total_calls >= 10) {
                // Complex successful task - suggest skill for future similar tasks
                try suggestions.append(.{
                    .action = .create_skill,
                    .skill_name = try self.allocator.dupe(u8, "successful-workflow"),
                    .reason = try std.fmt.allocPrint(self.allocator, "Complex task ({d} tool calls) completed successfully - worth capturing as skill template", .{total_calls}),
                    .confidence = 0.8,
                    .pattern_data = try std.fmt.allocPrint(self.allocator, "{{\"total_calls\":{d},\"tools\":{d}}}", .{
                        total_calls,
                        self.history.patterns.count(),
                    }),
                });
            }
        }

        // Detect failure patterns for memory update
        const failing_tools = try self.history.getFailingTools(1, 0.3);
        defer {
            for (failing_tools) |tool_name| {
                self.allocator.free(tool_name);
            }
            self.allocator.free(failing_tools);
        }

        for (failing_tools) |tool_name| {
            if (self.history.patterns.get(tool_name)) |pattern| {
                try suggestions.append(.{
                    .action = .update_memory,
                    .skill_name = null,
                    .reason = try std.fmt.allocPrint(self.allocator, "Tool '{s}' failed {d} time(s). Add to USER.md for future reference.", .{tool_name, pattern.failure_count}),
                    .confidence = 0.9,
                    .pattern_data = try std.fmt.allocPrint(self.allocator, "{{\"tool\":\"{s}\",\"failure_count\":{d}}}", .{tool_name, pattern.failure_count}),
                });
            }
        }

        const result = CheckpointResult{
            .should_checkpoint = suggestions.items.len > 0,
            .checkpoint_type = .task_complete,
            .suggestions = try suggestions.toOwnedSlice(),
        };

        // Free old suggestions and store new
        for (self.last_checkpoint_suggestions) |s| {
            self.allocator.free(s.reason);
            if (s.skill_name) |n| self.allocator.free(n);
            self.allocator.free(s.pattern_data);
        }
        self.last_checkpoint_suggestions = result.suggestions;

        return result;
    }

    /// Check if it's time for a periodic checkpoint
    pub fn shouldRunCheckpoint(self: *const SkillSelfImprove) bool {
        return self.tool_calls_since_checkpoint >= self.checkpoint_interval;
    }

    /// Generate skill content from a successful pattern
    pub fn generateSkillContent(self: *const SkillSelfImprove, tool_name: []const u8, args: []const u8) []const u8 {
        _ = tool_name;
        _ = args;
        _ = self;
        return "";
    }

    /// Log improvement to file for history tracking
    pub fn logImprovement(self: *SkillSelfImprove, suggestion: *const ImprovementSuggestion) !void {
        if (self.improvement_log_path == null) return;

        const timestamp = std.time.timestamp();
        const log_line = try std.fmt.allocPrint(self.allocator,
            "\\n{d} | {s} | {s} | {s} | {d:.2}",
            .{ timestamp, @tagName(suggestion.action), suggestion.reason, suggestion.pattern_data, suggestion.confidence }
        );
        defer self.allocator.free(log_line);

        const file = std.fs.cwd().openFile(self.improvement_log_path.?, .{ .mode = .append_only }) catch return;
        defer file.close();
        file.writeAll(log_line) catch return;
    }
};

/// Build self-evaluation prompt for LLM-based checkpoint (optional - more expensive)
pub fn buildCheckpointPrompt(history: *const ToolCallHistory) []const u8 {
    var prompt = std.ArrayList(u8).init(history.allocator);
    defer prompt.deinit();

    prompt.appendSlice("Self-Evaluation Checkpoint\n\n") catch return "";
    prompt.appendSlice("Evaluate the following tool usage patterns:\n\n") catch return "";

    var it = history.patterns.iterator();
    while (it.next()) |entry| {
        const p = entry.value_ptr.*;
        const total = p.success_count + p.failure_count;
        const rate = if (total > 0) @as(f32, @floatFromInt(p.success_count)) / @as(f32, @floatFromInt(total)) else 1.0;

        std.fmt.format("Tool: {s}\n  Success: {d}, Failures: {d}, Rate: {d:.1%}\n  Last args: {s}\n\n",
            .{ entry.key_ptr.*, p.success_count, p.failure_count, rate, p.last_args orelse "N/A" }) catch return "";
    }

    prompt.appendSlice("\nShould any of these patterns be captured as reusable skills? "
        ++ "Reply with JSON: {{\"skills_to_create\": [{{\"name\": \"...\", \"reason\": \"...\"}}], "
        ++ "\"memory_updates\": [{{\"fact\": \"...\"}}], \"none\": true}}\n") catch return "";

    return prompt.toOwnedSlice();
}

test "tool call history basic" {
    const allocator = std.testing.allocator;
    var history = try ToolCallHistory.init(allocator);
    defer history.deinit();

    try history.record("bash", true, 100, "ls -la");
    try history.record("bash", true, 150, "pwd");
    try history.record("read_file", true, 50, "foo.txt");

    try std.testing.expectEqual(@as(u32, 3), history.totalCalls());
    try std.testing.expectEqual(@as(f32, 1.0), history.successRate("bash"));
    try std.testing.expectEqual(@as(f32, 1.0), history.successRate("read_file"));
}

test "tool pattern failure detection" {
    const allocator = std.testing.allocator;
    var history = try ToolCallHistory.init(allocator);
    defer history.deinit();

    // 3 successes, 2 failures = 60% success rate
    try history.record("api_call", true, 100, "GET /users");
    try history.record("api_call", true, 100, "GET /posts");
    try history.record("api_call", true, 100, "GET /comments");
    try history.record("api_call", false, 100, "GET /fail");
    try history.record("api_call", false, 100, "GET /error");

    const rate = @as(f32, @floatFromInt(3)) / @as(f32, @floatFromInt(5));
    try std.testing.expectEqual(rate, history.successRate("api_call"));

    // Should be flagged as failing (2 failures, >30% failure rate)
    const failing = history.getFailingTools(2, 0.3);
    defer allocator.free(failing);
    try std.testing.expectEqual(@as(usize, 1), failing.len);
}