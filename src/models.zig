const std = @import("std");

/// Model capabilities and metadata
pub const ModelMetadata = struct {
    /// Model identifier (e.g., "gpt-4o", "claude-3-opus")
    name: []const u8,
    /// Display name
    display_name: []const u8,
    /// Provider (e.g., "openai", "anthropic")
    provider: []const u8,
    /// Context window size in tokens
    context_window: u32,
    /// Maximum output tokens
    max_output_tokens: u32,
    /// Supported features
    supports_function_calling: bool = true,
    supports_vision: bool = false,
    supports_streaming: bool = true,
    /// Cost per 1M input/output tokens (approximate)
    cost_per_million_input: f64 = 0,
    cost_per_million_output: f64 = 0,
    /// Speed tier (relative, lower is faster)
    speed_tier: u8 = 50,
    /// Reasoning quality tier (1-100, higher is better)
    reasoning_quality: u8 = 50,
};

/// Task requirements for routing
pub const TaskRequirements = struct {
    /// Minimum context window needed
    min_context_window: u32 = 128000,
    /// Needs function calling
    needs_function_calling: bool = false,
    /// Needs vision
    needs_vision: bool = false,
    /// Needs streaming
    needs_streaming: bool = true,
    /// Preferred speed (0-100, higher = faster preferred)
    speed_preference: u8 = 50,
    /// Preferred reasoning quality (0-100, higher = better)
    reasoning_preference: u8 = 50,
    /// Budget constraint (cost sensitive)
    budget_sensitive: bool = false,
};

/// Routing decision
pub const RoutingDecision = struct {
    /// Selected model metadata
    model: ModelMetadata,
    /// Reason for selection
    reason: []const u8,
    /// Score (higher is better)
    score: f64,
};

/// Model registry with metadata and routing
pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    models: std.StringArrayHashMapUnmanaged(ModelMetadata),

    pub fn init(allocator: std.mem.Allocator) !ModelRegistry {
        return .{
            .allocator = allocator,
            .models = try std.StringArrayHashMapUnmanaged(ModelMetadata).init(allocator, &.{}, &.{}),
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            const m = entry.value_ptr.*;
            self.allocator.free(m.display_name);
            self.allocator.free(m.provider);
            self.allocator.free(entry.key_ptr.*);
        }
        self.models.deinit(self.allocator);
    }

    pub fn register(self: *ModelRegistry, metadata: ModelMetadata) !void {
        const name_copy = try self.allocator.dupe(u8, metadata.name);
        errdefer self.allocator.free(name_copy);
        const display_name_copy = try self.allocator.dupe(u8, metadata.display_name);
        errdefer self.allocator.free(display_name_copy);
        const provider_copy = try self.allocator.dupe(u8, metadata.provider);
        errdefer self.allocator.free(provider_copy);
        var metadata_copy = metadata;
        metadata_copy.name = name_copy;
        metadata_copy.display_name = display_name_copy;
        metadata_copy.provider = provider_copy;
        try self.models.put(self.allocator, name_copy, metadata_copy);
    }

    /// Get model metadata by name
    pub fn get(self: *const ModelRegistry, name: []const u8) ?ModelMetadata {
        return self.models.get(name);
    }

    /// List all registered model names
    pub fn list(self: *const ModelRegistry) []const []const u8 {
        return self.models.keys();
    }

    /// Route to best model based on task requirements
    pub fn route(self: *const ModelRegistry, requirements: TaskRequirements) ?RoutingDecision {
        var best_model: ?ModelMetadata = null;
        var best_score: f64 = -1;
        var best_reason: []const u8 = "";

        var it = self.models.iterator();
        while (it.next()) |entry| {
            const model = entry.value_ptr.*;

            // Filter out models that don't meet hard requirements
            if (model.context_window < requirements.min_context_window) continue;
            if (requirements.needs_function_calling and !model.supports_function_calling) continue;
            if (requirements.needs_vision and !model.supports_vision) continue;
            if (requirements.needs_streaming and !model.supports_streaming) continue;

            // Calculate score
            var score: f64 = 0;

            // Speed preference contribution (0-30 points)
            const speed_diff = @abs(@as(i32, model.speed_tier) - @as(i32, requirements.speed_preference));
            score += 30.0 - @as(f64, @floatFromInt(speed_diff)) * 0.3;

            // Reasoning quality contribution (0-30 points)
            const reasoning_diff = @abs(@as(i32, model.reasoning_quality) - @as(i32, requirements.reasoning_preference));
            score += 30.0 - @as(f64, @floatFromInt(reasoning_diff)) * 0.3;

            // Cost contribution (0-20 points, lower cost = higher score)
            if (requirements.budget_sensitive) {
                const avg_cost = (model.cost_per_million_input + model.cost_per_million_output) / 2.0;
                score += 20.0 - avg_cost * 0.01;
            } else {
                score += 10.0; // Neutral cost score when not budget sensitive
            }

            // Bonus for exact capability match (0-10 points)
            if (model.supports_function_calling == requirements.needs_function_calling) {
                score += 5.0;
            }
            if (model.supports_vision == requirements.needs_vision) {
                score += 5.0;
            }

            if (score > best_score) {
                best_score = score;
                best_model = model;
                best_reason = "Best match for task requirements";
            }
        }

        if (best_model) |m| {
            return .{
                .model = m,
                .reason = best_reason,
                .score = best_score,
            };
        }
        return null;
    }

    /// Route to best model for a specific provider
    pub fn routeForProvider(self: *const ModelRegistry, provider: []const u8, requirements: TaskRequirements) ?RoutingDecision {
        var best_model: ?ModelMetadata = null;
        var best_score: f64 = -1;
        var best_reason: []const u8 = "";

        var it = self.models.iterator();
        while (it.next()) |entry| {
            const model = entry.value_ptr.*;

            if (!std.mem.eql(u8, model.provider, provider)) continue;

            // Filter out models that don't meet hard requirements
            if (model.context_window < requirements.min_context_window) continue;
            if (requirements.needs_function_calling and !model.supports_function_calling) continue;
            if (requirements.needs_vision and !model.supports_vision) continue;
            if (requirements.needs_streaming and !model.supports_streaming) continue;

            // Calculate score
            var score: f64 = 0;

            // Speed preference contribution (0-30 points)
            const speed_diff = @abs(@as(i32, model.speed_tier) - @as(i32, requirements.speed_preference));
            score += 30.0 - @as(f64, @floatFromInt(speed_diff)) * 0.3;

            // Reasoning quality contribution (0-30 points)
            const reasoning_diff = @abs(@as(i32, model.reasoning_quality) - @as(i32, requirements.reasoning_preference));
            score += 30.0 - @as(f64, @floatFromInt(reasoning_diff)) * 0.3;

            // Cost contribution (0-20 points, lower cost = higher score)
            if (requirements.budget_sensitive) {
                const avg_cost = (model.cost_per_million_input + model.cost_per_million_output) / 2.0;
                score += 20.0 - avg_cost * 0.01;
            } else {
                score += 10.0; // Neutral cost score when not budget sensitive
            }

            // Bonus for exact capability match (0-10 points)
            if (model.supports_function_calling == requirements.needs_function_calling) {
                score += 5.0;
            }
            if (model.supports_vision == requirements.needs_vision) {
                score += 5.0;
            }

            if (score > best_score) {
                best_score = score;
                best_model = model;
                best_reason = "Best match for task requirements";
            }
        }

        if (best_model) |m| {
            return .{
                .model = m,
                .reason = best_reason,
                .score = best_score,
            };
        }
        return null;
    }

    /// Get the cheapest model that meets requirements
    pub fn routeCheapest(self: *const ModelRegistry, requirements: TaskRequirements) ?ModelMetadata {
        var cheapest: ?ModelMetadata = null;
        var lowest_cost: f64 = std.math.inf(f64);

        var it = self.models.iterator();
        while (it.next()) |entry| {
            const model = entry.value_ptr.*;

            if (model.context_window < requirements.min_context_window) continue;
            if (requirements.needs_function_calling and !model.supports_function_calling) continue;
            if (requirements.needs_vision and !model.supports_vision) continue;
            if (requirements.needs_streaming and !model.supports_streaming) continue;

            const cost = model.cost_per_million_input + model.cost_per_million_output;
            if (cost < lowest_cost) {
                lowest_cost = cost;
                cheapest = model.*;
            }
        }

        return cheapest;
    }

    /// Get the fastest model that meets requirements
    pub fn routeFastest(self: *const ModelRegistry, requirements: TaskRequirements) ?ModelMetadata {
        var fastest: ?ModelMetadata = null;
        var lowest_speed_tier: u8 = 255;

        var it = self.models.iterator();
        while (it.next()) |entry| {
            const model = entry.value_ptr.*;

            if (model.context_window < requirements.min_context_window) continue;
            if (requirements.needs_function_calling and !model.supports_function_calling) continue;
            if (requirements.needs_vision and !model.supports_vision) continue;

            if (model.speed_tier < lowest_speed_tier) {
                lowest_speed_tier = model.speed_tier;
                fastest = model.*;
            }
        }

        return fastest;
    }
};

/// Create default model registry with known models
pub fn createDefaultModelRegistry(allocator: std.mem.Allocator) !ModelRegistry {
    var registry = try ModelRegistry.init(allocator);
    errdefer registry.deinit();

    // OpenAI Models
    try registry.register(.{
        .name = "gpt-4o",
        .display_name = "GPT-4o",
        .provider = "openai",
        .context_window = 128000,
        .max_output_tokens = 16384,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 5.0,
        .cost_per_million_output = 15.0,
        .speed_tier = 60,
        .reasoning_quality = 90,
    });

    try registry.register(.{
        .name = "gpt-4o-mini",
        .display_name = "GPT-4o Mini",
        .provider = "openai",
        .context_window = 128000,
        .max_output_tokens = 16384,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.15,
        .cost_per_million_output = 0.60,
        .speed_tier = 20,
        .reasoning_quality = 75,
    });

    try registry.register(.{
        .name = "gpt-4-turbo",
        .display_name = "GPT-4 Turbo",
        .provider = "openai",
        .context_window = 128000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 10.0,
        .cost_per_million_output = 30.0,
        .speed_tier = 70,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "o1-preview",
        .display_name = "OpenAI o1 Preview",
        .provider = "openai",
        .context_window = 128000,
        .max_output_tokens = 32768,
        .supports_function_calling = false,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 15.0,
        .cost_per_million_output = 60.0,
        .speed_tier = 85,
        .reasoning_quality = 98,
    });

    // Anthropic Models
    try registry.register(.{
        .name = "claude-3-5-sonnet",
        .display_name = "Claude 3.5 Sonnet",
        .provider = "anthropic",
        .context_window = 200000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 3.0,
        .cost_per_million_output = 15.0,
        .speed_tier = 45,
        .reasoning_quality = 92,
    });

    try registry.register(.{
        .name = "claude-3-5-haiku",
        .display_name = "Claude 3.5 Haiku",
        .provider = "anthropic",
        .context_window = 200000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.8,
        .cost_per_million_output = 4.0,
        .speed_tier = 15,
        .reasoning_quality = 78,
    });

    // Kimi Models
    try registry.register(.{
        .name = "kimi-k2.5",
        .display_name = "Kimi K2.5",
        .provider = "kimi",
        .context_window = 256000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 1.0,
        .cost_per_million_output = 4.0,
        .speed_tier = 40,
        .reasoning_quality = 92,
    });

    try registry.register(.{
        .name = "kimi-k2-turbo-preview",
        .display_name = "Kimi K2 Turbo",
        .provider = "kimi",
        .context_window = 256000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 2.0,
        .speed_tier = 25,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "moonshot-v1-8k",
        .display_name = "Kimi 8K",
        .provider = "kimi",
        .context_window = 8192,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.2,
        .cost_per_million_output = 2.0,
        .speed_tier = 30,
        .reasoning_quality = 80,
    });

    try registry.register(.{
        .name = "moonshot-v1-32k",
        .display_name = "Kimi 32K",
        .provider = "kimi",
        .context_window = 32768,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 1.0,
        .cost_per_million_output = 3.0,
        .speed_tier = 35,
        .reasoning_quality = 82,
    });

    try registry.register(.{
        .name = "moonshot-v1-128k",
        .display_name = "Kimi 128K",
        .provider = "kimi",
        .context_window = 131072,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 2.0,
        .cost_per_million_output = 5.0,
        .speed_tier = 40,
        .reasoning_quality = 84,
    });

    try registry.register(.{
        .name = "moonshot-v1-auto",
        .display_name = "Kimi Auto",
        .provider = "kimi",
        .context_window = 128000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 1.5,
        .cost_per_million_output = 4.0,
        .speed_tier = 38,
        .reasoning_quality = 83,
    });

    // MiniMax Models
    try registry.register(.{
        .name = "MiniMax-M2.7",
        .display_name = "MiniMax M2.7",
        .provider = "minimax",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.6,
        .cost_per_million_output = 1.2,
        .speed_tier = 35,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "MiniMax-M2.5",
        .display_name = "MiniMax M2.5",
        .provider = "minimax",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 1.0,
        .speed_tier = 30,
        .reasoning_quality = 86,
    });

    try registry.register(.{
        .name = "MiniMax-M2.1",
        .display_name = "MiniMax M2.1",
        .provider = "minimax",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 0.8,
        .speed_tier = 28,
        .reasoning_quality = 84,
    });

    try registry.register(.{
        .name = "MiniMax-M2",
        .display_name = "MiniMax M2",
        .provider = "minimax",
        .context_window = 10240,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.3,
        .cost_per_million_output = 0.6,
        .speed_tier = 25,
        .reasoning_quality = 82,
    });

    try registry.register(.{
        .name = "abab6.5s-chat",
        .display_name = "MiniMax 6.5S",
        .provider = "minimax",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.3,
        .cost_per_million_output = 0.6,
        .speed_tier = 25,
        .reasoning_quality = 78,
    });

    // ZAI Models
    try registry.register(.{
        .name = "glm-4.7",
        .display_name = "GLM 4.7",
        .provider = "zai",
        .context_window = 200000,
        .max_output_tokens = 128000,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.5,
        .speed_tier = 35,
        .reasoning_quality = 90,
    });

    try registry.register(.{
        .name = "glm-4.7-flash",
        .display_name = "GLM 4.7 Flash",
        .provider = "zai",
        .context_window = 200000,
        .max_output_tokens = 128000,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.0,
        .cost_per_million_output = 0.0,
        .speed_tier = 20,
        .reasoning_quality = 85,
    });

    try registry.register(.{
        .name = "glm-4.6",
        .display_name = "GLM 4.6",
        .provider = "zai",
        .context_window = 200000,
        .max_output_tokens = 64000,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.35,
        .cost_per_million_output = 1.5,
        .speed_tier = 32,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "glm-4-plus",
        .display_name = "GLM-4 Plus",
        .provider = "zai",
        .context_window = 128000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 1.0,
        .speed_tier = 30,
        .reasoning_quality = 86,
    });

    try registry.register(.{
        .name = "glm-4-flash",
        .display_name = "GLM-4 Flash",
        .provider = "zai",
        .context_window = 128000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.0,
        .cost_per_million_output = 0.0,
        .speed_tier = 15,
        .reasoning_quality = 78,
    });

    // Bailian Models
    try registry.register(.{
        .name = "qwen3.5-plus",
        .display_name = "Qwen 3.5 Plus",
        .provider = "bailian",
        .context_window = 128000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.5,
        .speed_tier = 30,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "qwen3.5-flash",
        .display_name = "Qwen 3.5 Flash",
        .provider = "bailian",
        .context_window = 128000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.1,
        .cost_per_million_output = 0.4,
        .speed_tier = 20,
        .reasoning_quality = 82,
    });

    try registry.register(.{
        .name = "qwen3-max",
        .display_name = "Qwen 3 Max",
        .provider = "bailian",
        .context_window = 32000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 1.2,
        .cost_per_million_output = 6.0,
        .speed_tier = 45,
        .reasoning_quality = 92,
    });

    try registry.register(.{
        .name = "qwen-plus",
        .display_name = "Qwen Plus",
        .provider = "bailian",
        .context_window = 131072,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.35,
        .cost_per_million_output = 1.4,
        .speed_tier = 32,
        .reasoning_quality = 86,
    });

    try registry.register(.{
        .name = "qwen-flash",
        .display_name = "Qwen Flash",
        .provider = "bailian",
        .context_window = 131072,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.2,
        .cost_per_million_output = 0.6,
        .speed_tier = 22,
        .reasoning_quality = 80,
    });

    // Volcano Models
    try registry.register(.{
        .name = "doubao-seed-1-8-251228",
        .display_name = "Doubao Seed 1.8",
        .provider = "volcano",
        .context_window = 256000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.2,
        .speed_tier = 30,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "doubao-pro-32k",
        .display_name = "Doubao Pro 32K",
        .provider = "volcano",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 1.5,
        .speed_tier = 30,
        .reasoning_quality = 85,
    });

    try registry.register(.{
        .name = "doubao-pro-128k",
        .display_name = "Doubao Pro 128K",
        .provider = "volcano",
        .context_window = 128000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 1.0,
        .cost_per_million_output = 2.5,
        .speed_tier = 35,
        .reasoning_quality = 86,
    });

    try registry.register(.{
        .name = "doubao-lite-32k",
        .display_name = "Doubao Lite 32K",
        .provider = "volcano",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.2,
        .cost_per_million_output = 0.5,
        .speed_tier = 18,
        .reasoning_quality = 78,
    });

    try registry.register(.{
        .name = "doubao-seed-1-6-250615",
        .display_name = "Doubao Seed 1.6",
        .provider = "volcano",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.3,
        .cost_per_million_output = 1.0,
        .speed_tier = 25,
        .reasoning_quality = 84,
    });

    // Coding Plan Providers
    try registry.register(.{
        .name = "kimi-k2.5",
        .display_name = "Kimi K2.5 (Plan)",
        .provider = "kimi-plan",
        .context_window = 256000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 1.0,
        .cost_per_million_output = 4.0,
        .speed_tier = 40,
        .reasoning_quality = 92,
    });

    try registry.register(.{
        .name = "MiniMax-M2.7",
        .display_name = "MiniMax M2.7 (Plan)",
        .provider = "minimax-plan",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.6,
        .cost_per_million_output = 1.2,
        .speed_tier = 35,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "qwen3.5-plus",
        .display_name = "Qwen 3.5 Plus (Plan)",
        .provider = "bailian-plan",
        .context_window = 128000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.5,
        .speed_tier = 30,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "ark-code-latest",
        .display_name = "Ark Coding Plan",
        .provider = "volcano-plan",
        .context_window = 256000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 1.5,
        .speed_tier = 30,
        .reasoning_quality = 86,
    });

    try registry.register(.{
        .name = "doubao-seed-code",
        .display_name = "Doubao Seed Code",
        .provider = "volcano-plan",
        .context_window = 256000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.2,
        .speed_tier = 28,
        .reasoning_quality = 85,
    });

    try registry.register(.{
        .name = "glm-4.7",
        .display_name = "GLM 4.7 Coding",
        .provider = "volcano-plan",
        .context_window = 200000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.5,
        .speed_tier = 32,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "kimi-k2-thinking",
        .display_name = "Kimi K2 Thinking Coding",
        .provider = "volcano-plan",
        .context_window = 256000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 2.0,
        .speed_tier = 35,
        .reasoning_quality = 90,
    });

    try registry.register(.{
        .name = "doubao-seed-code-preview-251028",
        .display_name = "Doubao Seed Code Preview",
        .provider = "volcano-plan",
        .context_window = 256000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.3,
        .cost_per_million_output = 1.0,
        .speed_tier = 26,
        .reasoning_quality = 84,
    });

    // Tencent Models
    try registry.register(.{
        .name = "hunyuan-lite",
        .display_name = "Hunyuan Lite",
        .provider = "tencent",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.1,
        .cost_per_million_output = 0.3,
        .speed_tier = 20,
        .reasoning_quality = 80,
    });

    try registry.register(.{
        .name = "hunyuan-standard",
        .display_name = "Hunyuan Standard",
        .provider = "tencent",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.3,
        .cost_per_million_output = 0.9,
        .speed_tier = 30,
        .reasoning_quality = 85,
    });

    try registry.register(.{
        .name = "hunyuan-pro",
        .display_name = "Hunyuan Pro",
        .provider = "tencent",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.6,
        .cost_per_million_output = 1.8,
        .speed_tier = 40,
        .reasoning_quality = 90,
    });

    try registry.register(.{
        .name = "hunyuan-t1",
        .display_name = "Hunyuan T1",
        .provider = "tencent",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.4,
        .cost_per_million_output = 1.2,
        .speed_tier = 35,
        .reasoning_quality = 88,
    });

    try registry.register(.{
        .name = "hunyuan-lite",
        .display_name = "Hunyuan Lite (Plan)",
        .provider = "tencent-plan",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.1,
        .cost_per_million_output = 0.3,
        .speed_tier = 20,
        .reasoning_quality = 80,
    });

    try registry.register(.{
        .name = "hunyuan-pro",
        .display_name = "Hunyuan Pro (Plan)",
        .provider = "tencent-plan",
        .context_window = 32000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = true,
        .supports_streaming = true,
        .cost_per_million_input = 0.6,
        .cost_per_million_output = 1.8,
        .speed_tier = 40,
        .reasoning_quality = 90,
    });


    // OpenRouter / Other providers
    try registry.register(.{
        .name = "deepseek-chat",
        .display_name = "DeepSeek Chat",
        .provider = "openrouter",
        .context_window = 64000,
        .max_output_tokens = 8192,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.14,
        .cost_per_million_output = 0.28,
        .speed_tier = 25,
        .reasoning_quality = 80,
    });

    try registry.register(.{
        .name = "nousresearch/hermes-3-llama-3.1-8b",
        .display_name = "Hermes 3 8B",
        .provider = "openrouter",
        .context_window = 128000,
        .max_output_tokens = 4096,
        .supports_function_calling = true,
        .supports_vision = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.0,
        .cost_per_million_output = 0.0,
        .speed_tier = 10,
        .reasoning_quality = 70,
    });

    return registry;
}
