//! Context Compressor - Automatic context window compression for long conversations
//! Aligned with Python Hermes agent/context_compressor.py

const std = @import("std");
const providers = @import("../providers/root.zig");
const agent_module = @import("agent.zig");
const Message = agent_module.Message;
const Role = agent_module.Role;
const LLMClient = providers.openai_compatible.LLMClient;
const ChatMessage = providers.ChatMessage;

const PRUNED_PLACEHOLDER = "[Old tool output cleared to save context space]";
const SUMMARY_PREFIX = "[CONTEXT COMPACTION] Earlier turns in this conversation were compacted to save context space. The summary below describes work that was already completed, and the current session state may still reflect that work (for example, files may already be changed). Use the summary and the current session state to continue from where things left off, and avoid repeating work:";
const MIN_SUMMARY_TOKENS = 2000;
const SUMMARY_RATIO = 0.20;
const SUMMARY_TOKENS_CEILING = 12000;
const SUMMARY_FAILURE_COOLDOWN_SECONDS = 600;
const CHARS_PER_TOKEN = 4;

pub const CompressResult = struct {
    messages: []Message,
    compressed: bool,
    saved_estimate: i64,
};

/// Estimate tokens roughly (characters / 4)
pub fn estimateTokens(messages: []const Message) u32 {
    var total_chars: usize = 0;
    for (messages) |msg| {
        total_chars += msg.content.len + 20; // +20 for role/metadata
    }
    return @as(u32, @intCast(total_chars / CHARS_PER_TOKEN));
}

pub const ContextCompressor = struct {
    allocator: std.mem.Allocator,
    model: []const u8,
    provider: providers.Provider,
    api_key: []const u8,
    context_length: u32,
    threshold_tokens: u32,
    tail_token_budget: u32,
    max_summary_tokens: u32,
    protect_first_n: u32 = 3,
    protect_last_n: u32 = 20,
    summary_target_ratio: f32 = 0.20,
    compression_count: u32 = 0,
    previous_summary: ?[]const u8 = null,
    summary_failure_cooldown_until: i64 = 0,
    quiet_mode: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        model: []const u8,
        provider: providers.Provider,
        api_key: []const u8,
        config_context_length: ?u32,
    ) ContextCompressor {
        const ctx_len = config_context_length orelse 128000;
        const threshold = @as(u32, @intFromFloat(@as(f32, @floatFromInt(ctx_len)) * 0.50));
        const target_ratio = @max(0.10, @min(0.80, 0.20));
        const target_tokens = @as(u32, @intFromFloat(@as(f32, @floatFromInt(threshold)) * target_ratio));
        const max_summary = @min(
            @as(u32, @intFromFloat(@as(f32, @floatFromInt(ctx_len)) * 0.05)),
            SUMMARY_TOKENS_CEILING,
        );
        return .{
            .allocator = allocator,
            .model = model,
            .provider = provider,
            .api_key = api_key,
            .context_length = ctx_len,
            .threshold_tokens = threshold,
            .tail_token_budget = target_tokens,
            .max_summary_tokens = max_summary,
            .summary_target_ratio = target_ratio,
        };
    }

    pub fn deinit(self: *ContextCompressor) void {
        if (self.previous_summary) |s| {
            self.allocator.free(s);
        }
    }

    pub fn shouldCompress(self: *const ContextCompressor, prompt_tokens: u32) bool {
        return prompt_tokens >= self.threshold_tokens;
    }

    /// Main compression entry point
    pub fn compress(self: *ContextCompressor, messages: []const Message, current_tokens: ?u32) !CompressResult {
        const n_messages = messages.len;
        if (n_messages <= self.protect_first_n + self.protect_last_n + 1) {
            return CompressResult{
                .messages = try duplicateMessages(self.allocator, messages),
                .compressed = false,
                .saved_estimate = 0,
            };
        }

        const display_tokens = current_tokens orelse estimateTokens(messages);

        // Phase 1: Prune old tool results
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const arena_alloc = arena.allocator();

        var working_messages = try arena_alloc.alloc(Message, n_messages);
        for (messages, 0..) |msg, i| {
            working_messages[i] = .{
                .role = msg.role,
                .content = try arena_alloc.dupe(u8, msg.content),
            };
        }

        const pruned_count = pruneOldToolResults(working_messages, self.protect_last_n * 3);
        if (pruned_count > 0 and !self.quiet_mode) {
            std.log.info("Pre-compression: pruned {d} old tool result(s)", .{pruned_count});
        }

        // Phase 2: Determine boundaries
        var compress_start = self.protect_first_n;
        compress_start = alignBoundaryForward(working_messages, compress_start);

        const compress_end = findTailCutByTokens(
            working_messages,
            compress_start,
            self.tail_token_budget,
            self.protect_last_n,
        );

        if (compress_start >= compress_end or compress_end > working_messages.len) {
            return CompressResult{
                .messages = try duplicateMessages(self.allocator, messages),
                .compressed = false,
                .saved_estimate = 0,
            };
        }

        if (!self.quiet_mode) {
            std.log.info("Context compression triggered ({d} tokens >= {d} threshold)", .{ display_tokens, self.threshold_tokens });
            std.log.info("Summarizing turns {d}-{d}, protecting {d} head + {d} tail messages", .{
                compress_start + 1,
                compress_end,
                compress_start,
                working_messages.len - compress_end,
            });
        }

        // Phase 3: Generate summary
        const turns_to_summarize = working_messages[compress_start..compress_end];
        const summary = try self.generateSummary(arena_alloc, turns_to_summarize);

        // Phase 4: Assemble compressed message list
        var result_list = std.array_list.AlignedManaged(Message, null).init(self.allocator);
        errdefer {
            for (result_list.items) |m| self.allocator.free(m.content);
            result_list.deinit();
        }

        // Append head
        for (0..compress_start) |i| {
            const msg = working_messages[i];
            var content = try self.allocator.dupe(u8, msg.content);
            if (i == 0 and msg.role == .system and self.compression_count == 0) {
                const note = "\n\n[Note: Some earlier conversation turns have been compacted into a handoff summary to preserve context space. The current session state may still reflect earlier work, so build on that summary and state rather than re-doing work.]";
                const new_content = try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ content, note });
                self.allocator.free(content);
                content = new_content;
            }
            try result_list.append(.{ .role = msg.role, .content = content });
        }

        // Insert summary
        var merge_summary_into_tail = false;
        if (summary) |s| {
            const last_head_role = if (compress_start > 0) working_messages[compress_start - 1].role else .user;
            const first_tail_role = if (compress_end < working_messages.len) working_messages[compress_end].role else .user;

            var summary_role: Role = if (last_head_role == .assistant or last_head_role == .tool) .user else .assistant;
            if (summary_role == first_tail_role) {
                const flipped: Role = if (summary_role == .user) .assistant else .user;
                if (flipped != last_head_role) {
                    summary_role = flipped;
                } else {
                    merge_summary_into_tail = true;
                }
            }

            if (!merge_summary_into_tail) {
                const prefixed = try std.fmt.allocPrint(self.allocator, "{s}\n{s}", .{ SUMMARY_PREFIX, s });
                try result_list.append(.{ .role = summary_role, .content = prefixed });
            }
        } else if (!self.quiet_mode) {
            std.log.debug("No summary generated — middle turns dropped without summary", .{});
        }

        // Append tail
        for (compress_end..working_messages.len) |i| {
            const msg = working_messages[i];
            var content = try self.allocator.dupe(u8, msg.content);
            if (merge_summary_into_tail and i == compress_end) {
                if (summary) |s| {
                    const merged = try std.fmt.allocPrint(self.allocator, "{s}\n\n{s}", .{ s, content });
                    self.allocator.free(content);
                    content = merged;
                }
            }
            try result_list.append(.{ .role = msg.role, .content = content });
        }

        self.compression_count += 1;

        var result_messages = try result_list.toOwnedSlice();
        result_messages = try sanitizeToolPairs(self.allocator, result_messages);

        const new_estimate = estimateTokens(result_messages);
        const saved_estimate: i64 = @as(i64, display_tokens) - @as(i64, new_estimate);

        if (!self.quiet_mode) {
            std.log.info("Compressed: {d} -> {d} messages (~{d} tokens saved)", .{
                n_messages,
                result_messages.len,
                saved_estimate,
            });
            std.log.info("Compression #{d} complete", .{self.compression_count});
        }

        return CompressResult{
            .messages = result_messages,
            .compressed = true,
            .saved_estimate = saved_estimate,
        };
    }

    fn generateSummary(self: *ContextCompressor, arena_alloc: std.mem.Allocator, turns: []const Message) !?[]const u8 {
        const now = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds();
        if (now < self.summary_failure_cooldown_until) {
            return null;
        }

        const summary_budget = computeSummaryBudget(turns, self.max_summary_tokens);
        const content_to_summarize = try serializeForSummary(arena_alloc, turns);

        var prompt_text = std.ArrayList(u8).empty;
        defer prompt_text.deinit(arena_alloc);
        var allocating = std.Io.Writer.Allocating.fromArrayList(arena_alloc, &prompt_text);
        if (self.previous_summary) |prev| {
            try allocating.writer.print(
                \\You are updating a context compaction summary. A previous compaction produced the summary below. New conversation turns have occurred since then and need to be incorporated.
                \\
                \\PREVIOUS SUMMARY:
                \\{s}
                \\
                \\NEW TURNS TO INCORPORATE:
                \\{s}
                \\
                \\Update the summary using this exact structure. PRESERVE all existing information that is still relevant. ADD new progress. Move items from "In Progress" to "Done" when completed. Remove information only if it is clearly obsolete.
                \\
                \\## Goal
                \\[What the user is trying to accomplish — preserve from previous summary, update if goal evolved]
                \\
                \\## Constraints & Preferences
                \\[User preferences, coding style, constraints, important decisions — accumulate across compactions]
                \\
                \\## Progress
                \\### Done
                \\[Completed work — include specific file paths, commands run, results obtained]
                \\### In Progress
                \\[Work currently underway]
                \\### Blocked
                \\[Any blockers or issues encountered]
                \\
                \\## Key Decisions
                \\[Important technical decisions and why they were made]
                \\
                \\## Relevant Files
                \\[Files read, modified, or created — with brief note on each. Accumulate across compactions.]
                \\
                \\## Next Steps
                \\[What needs to happen next to continue the work]
                \\
                \\## Critical Context
                \\[Any specific values, error messages, configuration details, or data that would be lost without explicit preservation]
                \\
                \\Target ~{d} tokens. Be specific — include file paths, command outputs, error messages, and concrete values rather than vague descriptions.
                \\
                \\Write only the summary body. Do not include any preamble or prefix.
            , .{ prev, content_to_summarize, summary_budget });
        } else {
            try allocating.writer.print(
                \\Create a structured handoff summary for a later assistant that will continue this conversation after earlier turns are compacted.
                \\
                \\TURNS TO SUMMARIZE:
                \\{s}
                \\
                \\Use this exact structure:
                \\
                \\## Goal
                \\[What the user is trying to accomplish]
                \\
                \\## Constraints & Preferences
                \\[User preferences, coding style, constraints, important decisions]
                \\
                \\## Progress
                \\### Done
                \\[Completed work — include specific file paths, commands run, results obtained]
                \\### In Progress
                \\[Work currently underway]
                \\### Blocked
                \\[Any blockers or issues encountered]
                \\
                \\## Key Decisions
                \\[Important technical decisions and why they were made]
                \\
                \\## Relevant Files
                \\[Files read, modified, or created — with brief note on each]
                \\
                \\## Next Steps
                \\[What needs to happen next to continue the work]
                \\
                \\## Critical Context
                \\[Any specific values, error messages, configuration details, or data that would be lost without explicit preservation]
                \\
                \\Target ~{d} tokens. Be specific — include file paths, command outputs, error messages, and concrete values rather than vague descriptions. The goal is to prevent the next assistant from repeating work or losing important details.
                \\
                \\Write only the summary body. Do not include any preamble or prefix.
            , .{ content_to_summarize, summary_budget });
        }

        var client = LLMClient.init(self.allocator, self.api_key, self.provider, self.model);
        defer client.deinit();

        prompt_text = allocating.toArrayList();
        const prompt_msg = ChatMessage{ .role = "user", .content = prompt_text.items };
        const raw = client.chat(&[_]ChatMessage{prompt_msg}) catch |err| {
            std.log.warn("Failed to generate context summary: {s}. Pausing summaries for {d}s.", .{
                @errorName(err),
                SUMMARY_FAILURE_COOLDOWN_SECONDS,
            });
            self.summary_failure_cooldown_until = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toSeconds() + SUMMARY_FAILURE_COOLDOWN_SECONDS;
            return null;
        };
        defer self.allocator.free(raw);

        // Store summary for iterative updates
        if (self.previous_summary) |s| self.allocator.free(s);
        self.previous_summary = try self.allocator.dupe(u8, raw);
        self.summary_failure_cooldown_until = 0;

        return self.previous_summary;
    }
};

fn duplicateMessages(allocator: std.mem.Allocator, messages: []const Message) ![]Message {
    var result = try allocator.alloc(Message, messages.len);
    errdefer allocator.free(result);
    for (messages, 0..) |msg, i| {
        result[i] = .{
            .role = msg.role,
            .content = try allocator.dupe(u8, msg.content),
        };
    }
    return result;
}

fn pruneOldToolResults(messages: []Message, protect_tail_count: u32) u32 {
    if (messages.len == 0) return 0;
    const prune_boundary: usize = if (messages.len > protect_tail_count) messages.len - protect_tail_count else 0;
    var pruned: u32 = 0;
    for (0..prune_boundary) |i| {
        if (messages[i].role == .tool) {
            if (messages[i].content.len > 200 and !std.mem.eql(u8, messages[i].content, PRUNED_PLACEHOLDER)) {
                messages[i].content = PRUNED_PLACEHOLDER;
                pruned += 1;
            }
        }
    }
    return pruned;
}

fn alignBoundaryForward(messages: []const Message, idx: u32) u32 {
    var i = idx;
    while (i < messages.len and messages[i].role == .tool) {
        i += 1;
    }
    return i;
}

fn alignBoundaryBackward(messages: []const Message, idx: u32) u32 {
    if (idx == 0 or idx >= messages.len) return idx;
    var check: i64 = @as(i64, idx) - 1;
    while (check >= 0 and messages[@as(usize, @intCast(check))].role == .tool) {
        check -= 1;
    }
    if (check >= 0 and messages[@as(usize, @intCast(check))].role == .assistant) {
        return @as(u32, @intCast(check));
    }
    return idx;
}

fn findTailCutByTokens(messages: []const Message, head_end: u32, token_budget: u32, min_tail: u32) u32 {
    const n = messages.len;
    var accumulated: u32 = 0;
    var cut_idx: u32 = @as(u32, @intCast(n));

    var i: i64 = @as(i64, @intCast(n)) - 1;
    while (i >= head_end) {
        const idx = @as(usize, @intCast(i));
        const msg_tokens = @as(u32, @intCast(messages[idx].content.len / CHARS_PER_TOKEN)) + 10;
        if (accumulated + msg_tokens > token_budget and (n - idx) >= min_tail) {
            break;
        }
        accumulated += msg_tokens;
        cut_idx = @intCast(idx);
        i -= 1;
    }

    const fallback_cut: u32 = if (n > min_tail) @as(u32, @intCast(n - min_tail)) else 0;
    if (cut_idx > fallback_cut) {
        cut_idx = fallback_cut;
    }
    if (cut_idx <= head_end) {
        cut_idx = fallback_cut;
    }

    cut_idx = alignBoundaryBackward(messages, cut_idx);
    return @max(cut_idx, head_end + 1);
}

fn computeSummaryBudget(turns: []const Message, max_summary_tokens: u32) u32 {
    var content_chars: usize = 0;
    for (turns) |msg| {
        content_chars += msg.content.len;
    }
    const content_tokens = @as(u32, @intCast(content_chars / CHARS_PER_TOKEN));
    const budget = @as(u32, @intFromFloat(@as(f32, @floatFromInt(content_tokens)) * SUMMARY_RATIO));
    return @max(MIN_SUMMARY_TOKENS, @min(budget, max_summary_tokens));
}

fn serializeForSummary(arena_alloc: std.mem.Allocator, turns: []const Message) ![]const u8 {
    var parts = std.ArrayList(u8).empty;
    defer parts.deinit(arena_alloc);
    var allocating = std.Io.Writer.Allocating.fromArrayList(arena_alloc, &parts);
    for (turns) |msg| {
        if (parts.items.len > 0) try allocating.writer.writeAll("\n\n");
        var content = msg.content;
        if (content.len > 3000) {
            const truncated = try std.fmt.allocPrint(arena_alloc, "{s}\n...[truncated]...\n{s}", .{
                content[0..2000],
                content[content.len - 800 ..],
            });
            content = truncated;
        }
        switch (msg.role) {
            .tool => {
                try allocating.writer.print("[TOOL RESULT]: {s}", .{content});
            },
            .assistant => {
                try allocating.writer.print("[ASSISTANT]: {s}", .{content});
            },
            else => {
                try allocating.writer.print("[{s}]: {s}", .{ @tagName(msg.role), content });
            },
        }
    }
    parts = allocating.toArrayList();
    return parts.items;
}

fn sanitizeToolPairs(allocator: std.mem.Allocator, messages: []Message) ![]Message {
    var surviving_call_ids = std.StringHashMap(void).init(allocator);
    defer surviving_call_ids.deinit();

    // Note: We don't have tool_call_id in Message struct, so this is a simplified version.
    // In the full implementation, Message would need to carry tool_call_id and tool_calls.
    // For now, since knot3bot Message only has role+content, we return messages as-is.
    // This limitation is acceptable because tool pair tracking requires schema changes.
    return messages;
}

// ============================================================================
// Tests
// ============================================================================

test "estimateTokens basic" {
    const messages = &[_]Message{
        .{ .role = .user, .content = "Hello world" },
        .{ .role = .assistant, .content = "Hi there!" },
    };
    const tokens = estimateTokens(messages);
    try std.testing.expect(tokens > 0);
}

test "pruneOldToolResults" {
    const messages = &[_]Message{
        .{ .role = .tool, .content = "This is a very long tool result that should definitely be pruned because it exceeds two hundred characters easily and contains lots of useful information that we don't want to keep around forever" },
        .{ .role = .user, .content = "Hello" },
        .{ .role = .assistant, .content = "Hi" },
    };
    // Need mutable array for pruning
    var alloc = std.testing.allocator;
    var msg_copy = try alloc.alloc(Message, messages.len);
    defer alloc.free(msg_copy);
    for (messages, 0..) |m, i| msg_copy[i] = .{ .role = m.role, .content = m.content };

    const pruned = pruneOldToolResults(msg_copy, 3);
    try std.testing.expectEqual(@as(u32, 1), pruned);
    try std.testing.expectEqualStrings(PRUNED_PLACEHOLDER, msg_copy[0].content);
}

test "compress short conversation no-op" {
    const allocator = std.testing.allocator;
    var compressor = ContextCompressor.init(allocator, "gpt-4o", .openai, "mock", 128000);
    defer compressor.deinit();

    const messages = &[_]Message{
        .{ .role = .system, .content = "You are helpful" },
        .{ .role = .user, .content = "Hello" },
    };
    const result = try compressor.compress(messages, null);
    defer {
        for (result.messages) |m| allocator.free(m.content);
        allocator.free(result.messages);
    }
    try std.testing.expect(!result.compressed);
    try std.testing.expectEqual(@as(usize, 2), result.messages.len);
}

test "findTailCutByTokens" {
    const messages = &[_]Message{
        .{ .role = .system, .content = "sys" },
        .{ .role = .user, .content = "u1" },
        .{ .role = .assistant, .content = "a1" },
        .{ .role = .user, .content = "u2" },
        .{ .role = .assistant, .content = "a2" },
        .{ .role = .user, .content = "u3" },
    };
    const cut = findTailCutByTokens(messages, 1, 100, 2);
    try std.testing.expect(cut > 1);
    try std.testing.expect(cut <= messages.len);
}
