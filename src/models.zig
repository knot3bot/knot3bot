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
    models: std.StringArrayHashMap(ModelMetadata),

    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return .{
            .allocator = allocator,
            .models = std.StringArrayHashMap(ModelMetadata).init(allocator),
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        var it = self.models.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            const m = entry.value_ptr.*;
            self.allocator.free(m.name);
            self.allocator.free(m.display_name);
            self.allocator.free(m.provider);
        }
        self.models.deinit();
    }

    /// Register a model with metadata
    pub fn register(self: *ModelRegistry, metadata: ModelMetadata) !void {
        const name_copy = try self.allocator.dupe(u8, metadata.name);
        errdefer self.allocator.free(name_copy);
        try self.models.put(name_copy, metadata);
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
    var registry = ModelRegistry.init(allocator);
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

    // OpenRouter / Other providers (using generic names that map to actual providers)
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
