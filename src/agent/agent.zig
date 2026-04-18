const std = @import("std");
const providers = @import("../providers/root.zig");
const tools = @import("../root.zig");
const skills = @import("skills.zig");
const skill_self_improve = @import("skill_self_improve.zig");
const SkillSelfImprove = skill_self_improve.SkillSelfImprove;
const context_compressor = @import("context_compressor.zig");
const trajectory = @import("trajectory.zig");
const models = @import("../models.zig");
const prompt_cache = @import("prompt_cache.zig");
const credential_pool = @import("credential_pool.zig");
const ToolRegistry = tools.ToolRegistry;
const SkillRegistry = skills.SkillRegistry;
const Skill = skills.Skill;
const LLMClient = providers.openai_compatible.LLMClient;
const RetryConfig = providers.openai_compatible.RetryConfig;
const Provider = providers.Provider;
const ChatMessage = providers.ChatMessage;
const ToolDef = providers.ToolDef;
const ToolResult = tools.ToolResult;
const ToolCallResult = providers.ChatResponse.ToolCall;
const ArrayList = std.ArrayList;

/// Stream callback for true streaming support
pub const StreamCallback = *const fn (chunk: []const u8, user_data: ?*anyopaque) void;

/// User data wrapper for streaming
pub const StreamUserData = struct {
    callback: StreamCallback,
    user_data: ?*anyopaque,
    allocator: std.mem.Allocator,
};

pub const AgentError = error{
    ToolNotFound,
    ToolExecutionFailed,
    MaxIterationsReached,
    TokenBudgetExceeded,
    LLMCallFailed,
    InvalidResponse,
    NoAPikey,
} || std.mem.Allocator.Error;

pub const Role = enum {
    system,
    user,
    assistant,
    tool,
};

pub const Message = struct {
    role: Role,
    content: []const u8,
    tool_call_id: ?[]const u8 = null,
    tool_calls_json: ?[]const u8 = null,
};


pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
};

/// ReAct step tracking for agent reasoning
pub const ReActStep = struct {
    step_number: u32,
    thought: []const u8,
    action: ?[]const u8,
    action_input: ?[]const u8,
    observation: ?[]const u8,
    result: ?[]const u8,
    error_msg: ?[]const u8 = null,
    duration_ms: u64,

    pub fn toJSON(self: *const ReActStep, allocator: std.mem.Allocator) ![]const u8 {
        var output: std.ArrayList(u8) = .empty;
        errdefer output.deinit(allocator);

        // Track temporary allocations to free them later
        var temp_allocs = std.ArrayList([]u8).init(allocator);
        defer {
            for (temp_allocs.items) |slice| allocator.free(slice);
            temp_allocs.deinit(allocator);
        }

        try output.appendSlice(allocator, "{\"step\":");
        const step_str = try std.fmt.allocPrint(allocator, "{}", .{self.step_number});
        try temp_allocs.append(allocator, step_str);
        try output.appendSlice(allocator, step_str);
        try output.appendSlice(allocator, ",\"thought\":\"");
        try output.appendSlice(allocator, self.thought);
        try output.appendSlice(allocator, "\"");

        if (self.action) |a| {
            try output.appendSlice(allocator, ",\"action\":\"");
            try output.appendSlice(allocator, a);
            try output.appendSlice(allocator, "\"");
        }
        if (self.action_input) |ai| {
            try output.appendSlice(allocator, ",\"action_input\":\"");
            try output.appendSlice(allocator, ai);
            try output.appendSlice(allocator, "\"");
        }
        if (self.observation) |o| {
            try output.appendSlice(allocator, ",\"observation\":\"");
            try output.appendSlice(allocator, o);
            try output.appendSlice(allocator, "\"");
        }
        if (self.result) |r| {
            try output.appendSlice(allocator, ",\"result\":\"");
            try output.appendSlice(allocator, r);
            try output.appendSlice(allocator, "\"");
        }
        if (self.error_msg) |e| {
            try output.appendSlice(allocator, ",\"error\":\"");
            try output.appendSlice(allocator, e);
            try output.appendSlice(allocator, "\"");
        }

        try output.appendSlice(allocator, ",\"duration_ms\":");
        const duration_str = try std.fmt.allocPrint(allocator, "{}", .{self.duration_ms});
        try temp_allocs.append(allocator, duration_str);
        try output.appendSlice(allocator, duration_str);
        try output.appendSlice(allocator, "}");

        return try output.toOwnedSlice(allocator);
    }
};

pub const TokenBudget = struct {
    max_tokens: u32,
    used_tokens: u32 = 0,
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,

    pub fn init(max: u32) TokenBudget {
        return .{ .max_tokens = max };
    }

    pub fn hasRemaining(self: *const TokenBudget) bool {
        return self.used_tokens < self.max_tokens;
    }

    pub fn consume(self: *TokenBudget, tokens: u32) void {
        self.used_tokens += tokens;
    }

    pub fn updateFromUsage(self: *TokenBudget, prompt: u32, completion: u32) void {
        self.prompt_tokens = prompt;
        self.completion_tokens = completion;
        self.used_tokens = prompt + completion;
    }
};

pub const IterationBudget = struct {
    max_iterations: u32,
    current: u32 = 0,

    pub fn init(max: u32) IterationBudget {
        return .{ .max_iterations = max };
    }

    pub fn hasRemaining(self: *const IterationBudget) bool {
        return self.current < self.max_iterations;
    }

    pub fn remaining(self: *const IterationBudget) u32 {
        return self.max_iterations - self.current;
    }

    pub fn tick(self: *IterationBudget) void {
        self.current += 1;
    }
};

pub const UsageStats = struct {
    prompt_tokens: u32 = 0,
    completion_tokens: u32 = 0,
    total_tokens: u32 = 0,
    api_calls: u32 = 0,
    tool_calls: u32 = 0,
    iterations: u32 = 0,
    errors: u32 = 0,

    pub fn update(self: *UsageStats, prompt: u32, completion: u32) void {
        self.prompt_tokens = prompt;
        self.completion_tokens = completion;
        self.total_tokens = prompt + completion;
    }
};

pub const AgentConfig = struct {
    model: []const u8 = "gpt-4o",
    provider: Provider = .openai,
    api_key: ?[]const u8 = null,
    system_prompt: ?[]const u8 = null,
    max_tokens: ?u32 = null,
    max_iterations: u32 = 100,
    temperature: f32 = 0.7,
    verbose: bool = false,
    context_compressor: ?context_compressor.ContextCompressor = null,
    enable_trajectory_recording: bool = false,
    trajectory_recorder: ?*const trajectory.TrajectoryRecorder = null,
    model_registry: ?*const models.ModelRegistry = null,
    enable_smart_routing: bool = false,
    prompt_cache: ?*prompt_cache.PromptCache = null,
    credential_pool: ?*credential_pool.CredentialPool = null,
    enable_skill_self_improve: bool = false,
    skill_self_improve_interval: u32 = 15, // Tool calls between checkpoints
    skill_self_improve: ?*SkillSelfImprove = null,
};

pub const LLMResult = struct {
    content: []const u8,
    tool_calls: ?[]ToolCallResult,
    tool_calls_json: ?[]const u8 = null,
    usage: ?LLMUsage = null,
};

pub const LLMUsage = struct {
    prompt: u32,
    completion: u32,
};
/// Step-by-step result for transparency
pub const StepResult = struct {
    steps: []ReActStep,
    final_answer: []const u8,
    usage: UsageStats,
    success: bool,
    error_msg: ?[]const u8 = null,
};

pub const Agent = struct {
    allocator: std.mem.Allocator,
    config: AgentConfig,
    registry: *const ToolRegistry,
    messages: ArrayList(Message),
    step_logs: ArrayList(ReActStep),
    client: ?LLMClient,
    has_api_key: bool,
    token_budget: TokenBudget,
    iteration_budget: IterationBudget,
    usage: UsageStats,
    skill_registry: ?*const SkillRegistry = null,
    active_skills: ArrayList([]const u8) = .empty,
    resolved_model: []const u8 = "",
    enable_trajectory_recording: bool = false,
    trajectory_recorder: ?*const trajectory.TrajectoryRecorder = null,
    model_registry: ?*const models.ModelRegistry = null,
    enable_smart_routing: bool = false,
    prompt_cache: ?*prompt_cache.PromptCache = null,
    credential_pool: ?*credential_pool.CredentialPool = null,
    anthropic_client: ?providers.anthropic.AnthropicClient = null,
    skill_self_improve: ?*SkillSelfImprove = null,
    pub fn init(allocator: std.mem.Allocator, config: AgentConfig, registry: *const ToolRegistry) Agent {
        var messages: ArrayList(Message) = .empty;
        if (config.system_prompt) |prompt| messages.append(allocator, .{ .role = .system, .content = prompt }) catch unreachable;
        var client: ?LLMClient = null;
        var anthropic_client: ?providers.anthropic.AnthropicClient = null;
        var resolved_model: []const u8 = config.model;
        if (config.enable_smart_routing) {
            if (config.model_registry) |mr| {
                if (mr.get(config.model)) |_| {
                    resolved_model = config.model;
                } else {
                    if (mr.routeForProvider(config.provider.internalName(), .{ .needs_function_calling = true, .needs_streaming = true })) |decision| {
                        resolved_model = allocator.dupe(u8, decision.model.name) catch config.model;
                    }
                }
            }
        }
        const effective_key = if (config.credential_pool) |pool| pool.nextKey() else (config.api_key orelse "");
        if (effective_key.len > 0) {
            if (config.provider == .anthropic) {
                anthropic_client = providers.anthropic.AnthropicClient.init(allocator, effective_key, resolved_model);
            } else {
                client = LLMClient.init(allocator, effective_key, config.provider, resolved_model);
            }
        }

        return .{
            .allocator = allocator,
            .config = config,
            .registry = registry,
            .messages = messages,
            .step_logs = .empty,
            .client = client,
            .anthropic_client = anthropic_client,
            .has_api_key = effective_key.len > 0,
            .prompt_cache = config.prompt_cache,
            .credential_pool = config.credential_pool,
            .token_budget = TokenBudget.init(config.max_tokens orelse 128000),
            .iteration_budget = IterationBudget.init(config.max_iterations),
            .usage = UsageStats{},
            .active_skills = .empty,
            .resolved_model = resolved_model,
            .enable_trajectory_recording = config.enable_trajectory_recording,
            .trajectory_recorder = config.trajectory_recorder,
            .model_registry = config.model_registry,
            .enable_smart_routing = config.enable_smart_routing,
            .skill_self_improve = config.skill_self_improve,
        };
    }

    pub fn deinit(self: *Agent) void {
        for (self.messages.items) |msg| {
            self.allocator.free(msg.content);
        }
        self.messages.deinit(self.allocator);

        for (self.step_logs.items) |*step| {
            self.allocator.free(step.thought);
            if (step.action) |a| self.allocator.free(a);
            if (step.action_input) |ai| self.allocator.free(ai);
            if (step.observation) |o| self.allocator.free(o);
            if (step.result) |r| self.allocator.free(r);
            if (step.error_msg) |e| self.allocator.free(e);
        }
        self.step_logs.deinit(self.allocator);

        for (self.active_skills.items) |s| {
            self.allocator.free(s);
        }
        self.active_skills.deinit(self.allocator);

        if (self.resolved_model.len > 0 and !std.mem.eql(u8, self.resolved_model, self.config.model)) {
            self.allocator.free(self.resolved_model);
        }

        if (self.config.context_compressor) |*cc| {
            cc.deinit();
        }

        if (self.client) |*c| c.deinit();
        if (self.anthropic_client) |*ac| ac.deinit();
    }

    /// Run agent with query and return detailed step-by-step result
    pub fn runWithSteps(self: *Agent, query: []const u8) !StepResult {
        self.step_logs.clearRetainingCapacity();
        self.usage = UsageStats{};

        try self.messages.append(self.allocator, .{ .role = .user, .content = query });
        errdefer {
            for (self.messages.items) |msg| self.allocator.free(msg.content);
        }

        // Prompt cache check
        if (self.prompt_cache) |cache| {
            if (cache.get(query)) |cached_response| {
                const cached_result = StepResult{
                    .steps = try self.step_logs.toOwnedSlice(self.allocator),
                    .final_answer = try self.allocator.dupe(u8, cached_response),
                    .usage = self.usage,
                    .success = true,
                };
                if (self.enable_trajectory_recording) {
                    if (self.trajectory_recorder) |recorder| {
                        recorder.save(self.resolved_model, true, cached_result.steps, self.messages.items) catch |err| {
                            std.log.warn("Failed to save trajectory: {s}", .{@errorName(err)});
                        };
                    }
                }
                return cached_result;
            }
        }

        while (self.iteration_budget.hasRemaining()) {
            self.iteration_budget.tick();
            self.usage.iterations += 1;
            const start_time = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toMilliseconds();

            // Context compression before LLM call if needed
            if (self.config.context_compressor) |*cc| {
                const token_estimate = context_compressor.estimateTokens(self.messages.items);
                if (cc.shouldCompress(token_estimate)) {
                    const compressed = blk: {
                        break :blk cc.compress(self.messages.items, token_estimate) catch |err| {
                            std.log.warn("Context compression failed: {s}", .{@errorName(err)});
                            break :blk null;
                        };
                    };
                    if (compressed) |result| {
                        // Free old messages and replace with compressed
                        for (self.messages.items) |msg| {
                            self.allocator.free(msg.content);
                        }
                        self.messages.deinit(self.allocator);
                        self.messages = std.ArrayList(Message).empty;
                        for (result.messages) |msg| {
                            self.messages.append(self.allocator, msg) catch {
                                self.allocator.free(msg.content);
                            };
                        }
                        self.allocator.free(result.messages);
                    }
                }
            }

            // Call LLM
            const llm_result = try self.callLLMWithTools();
            const step_duration: u64 = @intCast(std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toMilliseconds() - start_time);

            // Update usage from LLM response
            if (llm_result.usage) |u| {
                self.usage.update(u.prompt, u.completion);
                self.token_budget.updateFromUsage(u.prompt, u.completion);
            }
            self.usage.api_calls += 1;

            // Create step log
            var step = ReActStep{
                .step_number = self.iteration_budget.current,
                .thought = try self.allocator.dupe(u8, llm_result.content),
                .action = null,
                .action_input = null,
                .observation = null,
                .result = null,
                .error_msg = null,
                .duration_ms = step_duration,
            };
            defer {
                self.allocator.free(step.thought);
                if (step.action) |a| self.allocator.free(a);
                if (step.action_input) |ai| self.allocator.free(ai);
                if (step.observation) |o| self.allocator.free(o);
                if (step.result) |r| self.allocator.free(r);
                if (step.error_msg) |e| self.allocator.free(e);
            }

            // Add assistant message
            try self.messages.append(self.allocator, .{
                .role = .assistant,
                .content = llm_result.content,
                .tool_calls_json = llm_result.tool_calls_json,
            });

            // Handle tool calls
            if (llm_result.tool_calls) |tcs| {
                if (tcs.len > 0) {
                    step.action = try self.allocator.dupe(u8, tcs[0].function.name);
                    step.action_input = try self.allocator.dupe(u8, tcs[0].function.arguments);
                }

                var all_results: std.ArrayList(u8) = .empty;
                defer all_results.deinit(self.allocator);

                for (tcs) |tc| {
                    self.usage.tool_calls += 1;
                    const tool_start = std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toMilliseconds();

                    // Execute tool with error handling
                    const tool_result = self.executeToolWithError(tc.function.name, tc.function.arguments);
                    const tool_duration: u64 = @intCast(std.Io.Clock.Timestamp.now(std.Io.Threaded.global_single_threaded.io(), .real).raw.toMilliseconds() - tool_start);

                    const result_str = if (tool_result) |tr| tr else "{\"error\":\"Tool execution failed\"}";

                    if (self.config.verbose) {
                        std.debug.print("[Tool {s} took {d}ms]\n", .{ tc.function.name, tool_duration });
                    }

                    // Build observation string
                    if (all_results.items.len > 0) {
                        try all_results.appendSlice(self.allocator, ", ");
                    }
                    try all_results.appendSlice(self.allocator, result_str);

                    // Add tool message to conversation
                    const tool_msg = try std.fmt.allocPrint(self.allocator, "{s}", .{result_str});

                    try self.messages.append(self.allocator, .{
                        .role = .tool,
                        .content = tool_msg,
                        .tool_call_id = tc.id,
                    });

                    // Skill Self-Improvement: Record tool call for pattern tracking
                    if (self.skill_self_improve) |*si| {
                        const success = tool_result != null;
                        si.*.recordToolCall(tc.function.name, success, tool_duration, tc.function.arguments) catch {};
                    }
                }

                step.observation = try all_results.toOwnedSlice(self.allocator);

                // Log the step
                try self.step_logs.append(self.allocator, .{
                    .step_number = step.step_number,
                    .thought = try self.allocator.dupe(u8, step.thought),
                    .action = if (step.action) |a| try self.allocator.dupe(u8, a) else null,
                    .action_input = if (step.action_input) |ai| try self.allocator.dupe(u8, ai) else null,
                    .observation = if (step.observation) |o| try self.allocator.dupe(u8, o) else null,
                    .result = null,
                    .error_msg = null,
                    .duration_ms = step.duration_ms,
                });

                // Skill Self-Improvement: Check for periodic checkpoint
                if (self.skill_self_improve) |*si| {
                    if (si.*.shouldRunCheckpoint()) {
                        const checkpoint_result = si.*.runCheckpoint() catch null;
                        if (checkpoint_result) |cr| {
                            if (cr.should_checkpoint and self.config.verbose) {
                                std.debug.print("[Skill Self-Improve] Checkpoint triggered: {d} suggestions\n", .{cr.suggestions.len});
                                for (cr.suggestions) |s| {
                                    std.debug.print("  - {s}: {s} (confidence: {d:.2})\n", .{
                                        @tagName(s.action), s.reason, s.confidence});
                                }
                            }
                        }
                    }
                }

                continue;
            }

            // No tool calls - this is the final answer
            step.result = try self.allocator.dupe(u8, llm_result.content);
            try self.step_logs.append(self.allocator, step);
            step.thought = &.{}; // Prevent double-free in defer (empty slice is safe to free)

            const result = StepResult{
                .steps = try self.step_logs.toOwnedSlice(self.allocator),
                .final_answer = try self.allocator.dupe(u8, llm_result.content),
                .usage = self.usage,
                .success = true,
            };
            if (self.enable_trajectory_recording) {
                if (self.trajectory_recorder) |recorder| {
                    recorder.save(self.resolved_model, true, result.steps, self.messages.items) catch |err| {
                        std.log.warn("Failed to save trajectory: {s}", .{@errorName(err)});
                    };
                }
            }
            if (self.prompt_cache) |cache| {
                cache.put(query, result.final_answer) catch |err| {
                    std.log.warn("Failed to cache prompt: {s}", .{@errorName(err)});
                };
            }

            // Skill Self-Improvement: Run completion evaluation
            if (self.skill_self_improve) |*si| {
                const eval_result = si.*.runCompletionEvaluation() catch null;
                if (eval_result) |er| {
                    if (er.should_checkpoint and self.config.verbose) {
                        std.debug.print("[Skill Self-Improve] Completion eval: {d} suggestions\n", .{er.suggestions.len});
                    }
                }
            }

            return result;
        }

        // Max iterations reached
        self.usage.errors += 1;
        const fail_result = StepResult{
            .steps = try self.step_logs.toOwnedSlice(self.allocator),
            .final_answer = try self.allocator.dupe(u8, "Max iterations reached"),
            .usage = self.usage,
            .success = false,
            .error_msg = "Max iterations reached",
        };
        if (self.enable_trajectory_recording) {
            if (self.trajectory_recorder) |recorder| {
                recorder.save(self.resolved_model, false, fail_result.steps, self.messages.items) catch |err| {
                    std.log.warn("Failed to save trajectory: {s}", .{@errorName(err)});
                };
            }
        }
        return fail_result;
    }

    /// Simple run that returns just the final answer (backwards compatible)
    pub fn run(self: *Agent, query: []const u8) ![]const u8 {
        const result = try self.runWithSteps(query);
        return result.final_answer;
    }

    /// Streaming run that streams content as it arrives
    pub fn runStreaming(self: *Agent, query: []const u8, callback: StreamCallback, user_data: ?*anyopaque) ![]const u8 {
        self.step_logs.clearRetainingCapacity();
        self.usage = UsageStats{};
        try self.messages.append(self.allocator, .{ .role = .user, .content = query });
        if (!self.has_api_key or self.client == null) {
            const no_key_msg = "Final Answer: API key not configured.";
            callback(no_key_msg, user_data);
            return no_key_msg;
        }
        var msgs: ArrayList(ChatMessage) = .empty;
        defer msgs.deinit(self.allocator);
        for (self.messages.items) |msg| {
            const role = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
            };
            try msgs.append(self.allocator, .{ .role = role, .content = msg.content, .tool_call_id = msg.tool_call_id, .tool_calls_json = msg.tool_calls_json });
        }
        const tool_defs = try self.getToolDefs();
        defer {
            for (tool_defs) |td| {
                self.allocator.free(td.function.name);
                if (td.function.description) |d| self.allocator.free(d);
                if (td.function.parameters) |p| self.allocator.free(p);
            }
            self.allocator.free(tool_defs);
        }
        var stream_data = StreamUserData{ .callback = callback, .user_data = user_data, .allocator = self.allocator };
        var client_val: LLMClient = self.client.?; // Store unwrapped value
        try providers.openai_compatible.chatStreamWithRetry(&client_val, msgs.items, RetryConfig{}, struct {
            fn func(chunk: []const u8, ud: ?*anyopaque) void {
                const data = @as(*StreamUserData, @ptrCast(@alignCast(ud.?)));
                data.callback(chunk, data.user_data);
            }
        }.func, &stream_data);
        while (self.iteration_budget.hasRemaining()) {
            self.iteration_budget.tick();
            self.usage.iterations += 1;
            const llm_result = try self.callLLMWithTools();
            if (llm_result.usage) |u| self.usage.update(u.prompt, u.completion);
            self.usage.api_calls += 1;
            try self.messages.append(self.allocator, .{ .role = .assistant, .content = llm_result.content, .tool_calls_json = llm_result.tool_calls_json });
            if (llm_result.tool_calls) |tcs| {
                if (tcs.len > 0) {
                    var all_results: std.ArrayList(u8) = .empty;
                    defer all_results.deinit(self.allocator);
                    for (tcs) |tc| {
                        self.usage.tool_calls += 1;
                        const tool_result = self.executeToolWithError(tc.function.name, tc.function.arguments);
                        const result_str = if (tool_result) |tr| tr else "{\"error\":\"Tool execution failed\"}";
                        if (all_results.items.len > 0) try all_results.appendSlice(self.allocator, ", ");
                        try all_results.appendSlice(self.allocator, result_str);
                        const tool_msg = try std.fmt.allocPrint(self.allocator, "{s}", .{result_str});
                        try self.messages.append(self.allocator, .{ .role = .tool, .content = tool_msg, .tool_call_id = tc.id });
                    }
                    const indicator = try std.fmt.allocPrint(self.allocator, "[Tool(s) executed. Results: {s}]", .{try all_results.toOwnedSlice(self.allocator)});
                    defer self.allocator.free(indicator);
                    callback(indicator, user_data);
                    continue;
                }
            }
            return llm_result.content;
        }
        return "Max iterations reached";
    }
    /// Execute tool and return result or null on error
    fn executeToolWithError(self: *Agent, tool_name: []const u8, arguments: []const u8) ?[]const u8 {
        const result = self.registry.call(self.allocator, tool_name, arguments) catch |err| {
            self.usage.errors += 1;
            if (self.config.verbose) {
                std.debug.print("[Tool error: {s} - {}]\n", .{ tool_name, err });
            }
            return null;
        };

        if (!result.success) {
            self.usage.errors += 1;
            if (self.config.verbose) {
                std.debug.print("[Tool failed: {s} - {s}]\n", .{ tool_name, result.error_msg orelse "unknown" });
            }
        }

        return self.allocator.dupe(u8, result.output) catch null;
    }

    fn callLLMWithTools(self: *Agent) !LLMResult {
        if (!self.has_api_key or (self.client == null and self.anthropic_client == null)) {
            return .{
                .content = try self.allocator.dupe(u8, "Final Answer: API key not configured. Please set OPENAI_API_KEY environment variable."),
                .tool_calls = null,
                .usage = null,
            };
        }

        if (self.config.provider == .anthropic) {
            if (self.anthropic_client) |*ac| {
                var anthropic_msgs: ArrayList(providers.anthropic.AnthropicMessage) = .empty;
                defer anthropic_msgs.deinit(self.allocator);
                for (self.messages.items) |msg| {
                    const role = switch (msg.role) {
                        .system => "system",
                        .user => "user",
                        .assistant => "assistant",
                        .tool => "user",
                    };
                    try anthropic_msgs.append(self.allocator, .{ .role = role, .content = msg.content });
                }
                const tool_defs = try self.getToolDefs();
                defer {
                    for (tool_defs) |td| {
                        self.allocator.free(td.function.name);
                        if (td.function.description) |d| self.allocator.free(d);
                        if (td.function.parameters) |p| self.allocator.free(p);
                    }
                    self.allocator.free(tool_defs);
                }
                var anthropic_tools: ArrayList(providers.anthropic.ToolDef) = .empty;
                defer anthropic_tools.deinit(self.allocator);
                for (tool_defs) |td| {
                    try anthropic_tools.append(self.allocator, .{
                        .name = td.function.name,
                        .description = td.function.description,
                        .input_schema = td.function.parameters,
                    });
                }
                const raw = try ac.chatWithTools(anthropic_msgs.items, anthropic_tools.items);
                defer self.allocator.free(raw);
                // Parse the OpenAI-compatible JSON returned by Anthropic adapter
                var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
                    return .{ .content = try self.allocator.dupe(u8, raw), .tool_calls = null, .usage = null };
                };
                defer parsed.deinit();
                var content: ?[]const u8 = null;
                var tool_calls: ?[]ToolCallResult = null;
                var tool_calls_json: ?[]const u8 = null;
                var usage: ?LLMUsage = null;
                if (parsed.value == .object) {
                    const obj = parsed.value.object;
                    if (obj.get("usage")) |u| {
                        if (u == .object) {
                            var prompt_tokens: u32 = 0;
                            var completion_tokens: u32 = 0;
                            if (u.object.get("prompt_tokens")) |pt| {
                                if (pt == .integer) prompt_tokens = @intCast(pt.integer);
                            }
                            if (u.object.get("completion_tokens")) |ct| {
                                if (ct == .integer) completion_tokens = @intCast(ct.integer);
                            }
                            if (prompt_tokens > 0 or completion_tokens > 0) {
                                usage = .{ .prompt = prompt_tokens, .completion = completion_tokens };
                            }
                        }
                    }
                    if (obj.get("choices")) |choices| {
                        if (choices == .array and choices.array.items.len > 0) {
                            const choice = choices.array.items[0];
                            if (choice == .object) {
                                if (choice.object.get("message")) |msg| {
                                    if (msg == .object) {
                                        if (msg.object.get("content")) |c| {
                                            if (c == .string) content = c.string;
                                        }
                                        if (msg.object.get("tool_calls")) |tcs| {
                                            if (tcs == .array and tcs.array.items.len > 0) {
                                                var parsed_tcs = ArrayList(ToolCallResult).empty;
                                                defer parsed_tcs.deinit(self.allocator);
                                                for (tcs.array.items) |tc| {
                                                    if (tc == .object) {
                                                        const tco = tc.object;
                                                        var fn_n: []const u8 = "";
                                                        var fn_a: []const u8 = "{}";
                                                        if (tco.get("function")) |f| {
                                                            if (f == .object) {
                                                                if (f.object.get("name")) |n| {
                                                                    if (n == .string) fn_n = n.string;
                                                                }
                                                                if (f.object.get("arguments")) |a| {
                                                                    if (a == .string) fn_a = a.string;
                                                                }
                                                            }
                                                        }
                                                        const tc_id = if (tco.get("id")) |v| if (v == .string) v.string else "" else "";
                                                        const tc_type = if (tco.get("type")) |v| if (v == .string) v.string else "function" else "function";
                                                        parsed_tcs.append(self.allocator, .{
                                                            .id = try self.allocator.dupe(u8, tc_id),
                                                            .type = try self.allocator.dupe(u8, tc_type),
                                                            .function = .{
                                                                .name = try self.allocator.dupe(u8, fn_n),
                                                                .arguments = try self.allocator.dupe(u8, fn_a),
                                                            },
                                                        }) catch unreachable;
                                                    }
                                                }
                                                if (parsed_tcs.items.len > 0) {
                                                    var json_buf: std.ArrayList(u8) = .empty;
                                                    defer json_buf.deinit(self.allocator);
                                                    try json_buf.appendSlice(self.allocator, "[");
                                                    for (parsed_tcs.items, 0..) |tc, i| {
                                                        if (i > 0) try json_buf.appendSlice(self.allocator, ",");
                                                        try json_buf.appendSlice(self.allocator, "{\"id\":\"");
                                                        try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.id);
                                                        try json_buf.appendSlice(self.allocator, "\",\"type\":\"");
                                                        try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.type);
                                                        try json_buf.appendSlice(self.allocator, "\",\"function\":{\"name\":\"");
                                                        try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.function.name);
                                                        try json_buf.appendSlice(self.allocator, "\",\"arguments\":\"");
                                                        try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.function.arguments);
                                                        try json_buf.appendSlice(self.allocator, "\"}}");
                                                    }
                                                    try json_buf.appendSlice(self.allocator, "]");
                                                    tool_calls_json = try json_buf.toOwnedSlice(self.allocator);
                                                    tool_calls = try parsed_tcs.toOwnedSlice(self.allocator);
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                return .{
                    .content = try self.allocator.dupe(u8, content orelse raw),
                    .tool_calls = tool_calls,
                    .tool_calls_json = tool_calls_json,
                    .usage = usage,
                };
            }
        }

        if (!self.has_api_key or self.client == null) {
            return .{
                .content = try self.allocator.dupe(u8, "Final Answer: API key not configured. Please set OPENAI_API_KEY environment variable."),
                .tool_calls = null,
                .usage = null,
            };
        }

        var msgs: ArrayList(ChatMessage) = .empty;
        defer msgs.deinit(self.allocator);
        for (self.messages.items) |msg| {
            const role = switch (msg.role) {
                .system => "system",
                .user => "user",
                .assistant => "assistant",
                .tool => "tool",
            };
            try msgs.append(self.allocator, .{ .role = role, .content = msg.content, .tool_call_id = msg.tool_call_id, .tool_calls_json = msg.tool_calls_json });
        }

        const tool_defs = try self.getToolDefs();
        defer {
            for (tool_defs) |td| {
                self.allocator.free(td.function.name);
                if (td.function.description) |d| self.allocator.free(d);
                if (td.function.parameters) |p| self.allocator.free(p);
            }
            self.allocator.free(tool_defs);
        }

        if (self.config.verbose) {
            std.debug.print("[Step {d}] Thinking with {d} msgs, {d} tools...\n", .{
                self.iteration_budget.current, self.messages.items.len, tool_defs.len,
            });
        }

        const raw = try self.client.?.chatWithTools(msgs.items, tool_defs);

        // Try to parse usage from response
        var usage: ?LLMUsage = null;

        // Parse the response
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            return .{ .content = try self.allocator.dupe(u8, raw), .tool_calls = null, .usage = null };
        };
        defer parsed.deinit();

        var content: ?[]const u8 = null;
        var tool_calls: ?[]ToolCallResult = null;
        var tool_calls_json: ?[]const u8 = null;

        // Try to extract usage if present
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("usage")) |u| {
                if (u == .object) {
                    var prompt_tokens: u32 = 0;
                    var completion_tokens: u32 = 0;
                    if (u.object.get("prompt_tokens")) |pt| {
                        if (pt == .integer) prompt_tokens = @intCast(pt.integer);
                    }
                    if (u.object.get("completion_tokens")) |ct| {
                        if (ct == .integer) completion_tokens = @intCast(ct.integer);
                    }
                    if (prompt_tokens > 0 or completion_tokens > 0) {
                        usage = .{ .prompt = prompt_tokens, .completion = completion_tokens };
                    }
                }
            }
        }

        // Re-parse since we may have consumed it
        parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch {
            return .{ .content = try self.allocator.dupe(u8, raw), .tool_calls = null, .usage = usage };
        };
        defer parsed.deinit();

        if (parsed.value == .object) {
            const obj = parsed.value.object;
            if (obj.get("choices")) |choices| {
                if (choices == .array and choices.array.items.len > 0) {
                    const choice = choices.array.items[0];
                    if (choice == .object) {
                        if (choice.object.get("message")) |msg| {
                            if (msg == .object) {
                                if (msg.object.get("content")) |c| {
                                    if (c == .string) content = c.string;
                                }
                                if (msg.object.get("tool_calls")) |tcs| {
                                    if (tcs == .array and tcs.array.items.len > 0) {
                                        var parsed_tcs = ArrayList(ToolCallResult).empty;
                                        defer parsed_tcs.deinit(self.allocator);
                                        for (tcs.array.items) |tc| {
                                            if (tc == .object) {
                                                const tco = tc.object;
                                                var fn_n: []const u8 = "";
                                                var fn_a: []const u8 = "{}";
                                                if (tco.get("function")) |f| {
                                                    if (f == .object) {
                                                        if (f.object.get("name")) |n| {
                                                            if (n == .string) fn_n = n.string;
                                                        }
                                                        if (f.object.get("arguments")) |a| {
                                                            if (a == .string) fn_a = a.string;
                                                        }
                                                    }
                                                }
                                                const tc_id = if (tco.get("id")) |v| if (v == .string) v.string else "" else "";
                                                const tc_type = if (tco.get("type")) |v| if (v == .string) v.string else "function" else "function";
                                                parsed_tcs.append(self.allocator, .{
                                                    .id = try self.allocator.dupe(u8, tc_id),
                                                    .type = try self.allocator.dupe(u8, tc_type),
                                                    .function = .{
                                                        .name = try self.allocator.dupe(u8, fn_n),
                                                        .arguments = try self.allocator.dupe(u8, fn_a),
                                                    },
                                                }) catch unreachable;
                                            }
                                        }
                                        if (parsed_tcs.items.len > 0) {
                                            var json_buf: std.ArrayList(u8) = .empty;
                                            defer json_buf.deinit(self.allocator);
                                            try json_buf.appendSlice(self.allocator, "[");
                                            for (parsed_tcs.items, 0..) |tc, i| {
                                                if (i > 0) try json_buf.appendSlice(self.allocator, ",");
                                                try json_buf.appendSlice(self.allocator, "{\"id\":\"");
                                                try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.id);
                                                try json_buf.appendSlice(self.allocator, "\",\"type\":\"");
                                                try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.type);
                                                try json_buf.appendSlice(self.allocator, "\",\"function\":{\"name\":\"");
                                                try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.function.name);
                                                try json_buf.appendSlice(self.allocator, "\",\"arguments\":\"");
                                                try escapeJsonStringToBuffer(&json_buf, self.allocator, tc.function.arguments);
                                                try json_buf.appendSlice(self.allocator, "\"}}");
                                            }
                                            try json_buf.appendSlice(self.allocator, "]");
                                            tool_calls_json = try json_buf.toOwnedSlice(self.allocator);
                                            tool_calls = try parsed_tcs.toOwnedSlice(self.allocator);
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }

        return .{
            .content = try self.allocator.dupe(u8, content orelse raw),
            .tool_calls = tool_calls,
            .tool_calls_json = tool_calls_json,
            .usage = usage,
        };
    }


    fn escapeJsonStringToBuffer(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, str: []const u8) !void {
        for (str) |c| {
            switch (c) {
                '"' => try buf.appendSlice(allocator, "\\\""),
                '\\' => try buf.appendSlice(allocator, "\\\\"),
                '\n' => try buf.appendSlice(allocator, "\\n"),
                '\r' => try buf.appendSlice(allocator, "\\r"),
                '\t' => try buf.appendSlice(allocator, "\\t"),
                else => try buf.append(allocator, c),
            }
        }
    }

    fn getToolDefs(self: *Agent) ![]ToolDef {
        const specs = self.registry.list();
        const result = try self.allocator.alloc(ToolDef, specs.len);
        errdefer self.allocator.free(result);

        for (specs, 0..) |entry, idx| {
            result[idx] = .{
                .type = "function",
                .function = .{
                    .name = try self.allocator.dupe(u8, entry.spec.name),
                    .description = try self.allocator.dupe(u8, entry.spec.description),
                    .parameters = try self.allocator.dupe(u8, entry.spec.parameters_json),
                },
            };
        }
        return result;
    }

    pub fn getUsageStats(self: *const Agent) UsageStats {
        return self.usage;
    }

    pub fn hasBudget(self: *const Agent) bool {
        return self.token_budget.hasRemaining() and self.iteration_budget.hasRemaining();
    }

    pub fn getStepLogs(self: *const Agent) []const ReActStep {
        return self.step_logs.items;
    }

    /// Load a skill by name and append its prompt to messages
    pub fn loadSkill(self: *Agent, skill_name: []const u8) !bool {
        const registry = self.skill_registry orelse return false;
        const prompt = registry.loadSkillPrompt(skill_name, self.allocator) catch return false;
        if (prompt) |p| {
            const skill_msg = try std.fmt.allocPrint(self.allocator, "[SKILL: {s}]\n{s}", .{ skill_name, p });
            defer self.allocator.free(skill_msg);
            try self.messages.append(self.allocator, .{ .role = .system, .content = skill_msg });
            try self.active_skills.append(self.allocator, try self.allocator.dupe(u8, skill_name));
            return true;
        }
        return false;
    }

    pub fn getActiveSkills(self: *const Agent) []const []const u8 {
        return self.active_skills.items;
    }

    pub fn setSkillRegistry(self: *Agent, registry: *const SkillRegistry) void {
        self.skill_registry = registry;
    }

    /// Load message history from JSON string (e.g., from session storage)
    pub fn loadHistoryFromJSON(self: *Agent, json_str: []const u8) !void {
        const parsed = std.json.parseFromSlice([]struct { role: []const u8, content: []const u8, timestamp: i64 }, self.allocator, json_str, .{}) catch |err| {
            std.log.warn("Failed to parse history JSON: {s}", .{@errorName(err)});
            return;
        };
        defer parsed.deinit();

        for (parsed.value) |msg| {
            const content_copy = try self.allocator.dupe(u8, msg.content);
            errdefer self.allocator.free(content_copy);

            const role_enum: Role = if (std.mem.eql(u8, msg.role, "system")) .system else if (std.mem.eql(u8, msg.role, "user")) .user else if (std.mem.eql(u8, msg.role, "assistant")) .assistant else if (std.mem.eql(u8, msg.role, "tool")) .tool else .user;

            try self.messages.append(self.allocator, .{
                .role = role_enum,
                .content = content_copy,
            });
        }
    }

    pub fn appendMessage(self: *Agent, role: Role, content: []const u8) !void {
        const content_copy = try self.allocator.dupe(u8, content);
        errdefer self.allocator.free(content_copy);
        try self.messages.append(self.allocator, .{ .role = role, .content = content_copy });
    }
};

pub fn createDefaultSystemPrompt(allocator: std.mem.Allocator, registry: *const ToolRegistry) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &list);

    try allocating.writer.writeAll(
        \\You are knot3bot, an intelligent AI assistant built with Zig.
        \\
        \\Guidelines:
        \\- Use tools when you need to perform actions or get information
        \\- Be concise and helpful in your responses
        \\- When using tools, wait for results before responding
        \\- If a tool fails, try an alternative approach or explain the issue
        \\
    );

    try allocating.writer.writeAll("\nAvailable tools:\n");
    for (registry.list()) |entry| {
        try allocating.writer.print("  - {s}: {s}\n", .{ entry.spec.name, entry.spec.description });
    }

    list = allocating.toArrayList();
    return try list.toOwnedSlice(allocator);
}

/// Create an enhanced system prompt with ReAct reasoning
pub fn createReActSystemPrompt(allocator: std.mem.Allocator, registry: *const ToolRegistry) ![]const u8 {
    var list: std.ArrayList(u8) = .empty;
    defer list.deinit(allocator);
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &list);

    try allocating.writer.writeAll(
        \\You are knot3bot, an AI assistant that uses the ReAct (Reasoning + Acting) pattern.
        \\
        \\Your reasoning process:
        \\1. THOUGHT: Analyze the request and decide what to do
        \\2. ACTION: Select and call a tool if needed (format: tool_name({"arg": "value"}))
        \\3. OBSERVATION: Review the tool's result
        \\4. Repeat until you can give a final answer
        \\5. Final Answer: [your response]
        \\
        \\Guidelines:
        \\- Always show your reasoning process
        \\- Use tools proactively when they can help
        \\- Handle tool errors gracefully and try alternatives
        \\- Be concise but thorough
        \\
    );

    try allocating.writer.writeAll("\nAvailable tools:\n");
    for (registry.list()) |entry| {
        try allocating.writer.print("  - {s}: {s}\n", .{ entry.spec.name, entry.spec.description });
    }

    list = allocating.toArrayList();
    return try list.toOwnedSlice(allocator);
}
