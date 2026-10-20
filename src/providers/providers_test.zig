//! Provider and model tests
const std = @import("std");
const providers = @import("root.zig");
const Provider = providers.Provider;
const models = @import("../models.zig");
const ModelRegistry = models.ModelRegistry;
const TaskRequirements = models.TaskRequirements;
const ModelMetadata = models.ModelMetadata;

// ============================================================================
// Provider Tests
// ============================================================================

test "Provider enum has expected values" {
    // Verify all expected providers exist
    try std.testing.expectEqual(@as(u8, 0), @backingInt(Provider.openai));
    try std.testing.expectEqual(@as(u8, 1), @backingInt(Provider.anthropic));
    try std.testing.expectEqual(@as(u8, 2), @backingInt(Provider.deepseek));
    try std.testing.expectEqual(@as(u8, 3), @backingInt(Provider.kimi));
    try std.testing.expectEqual(@as(u8, 4), @backingInt(Provider.minimax));
    try std.testing.expectEqual(@as(u8, 5), @backingInt(Provider.zai));
    try std.testing.expectEqual(@as(u8, 6), @backingInt(Provider.bailian));
    try std.testing.expectEqual(@as(u8, 7), @backingInt(Provider.volcano));
}

test "Provider.name returns expected string" {
    try std.testing.expectEqualStrings("OpenAI", Provider.openai.name());
    try std.testing.expectEqualStrings("Anthropic", Provider.anthropic.name());
    try std.testing.expectEqualStrings("Kimi (Moonshot)", Provider.kimi.name());
    try std.testing.expectEqualStrings("MiniMax", Provider.minimax.name());
    try std.testing.expectEqualStrings("Z.ai (Zhipu)", Provider.zai.name());
    try std.testing.expectEqualStrings("Bailian (Alibaba)", Provider.bailian.name());
    try std.testing.expectEqualStrings("Volcano Engine", Provider.volcano.name());
}

test "Provider.models returns non-empty list" {
    const openai_models = Provider.openai.models();
    try std.testing.expect(openai_models.len > 0);
    var has_gpt4o = false;
    for (openai_models) |model_name| {
        if (std.mem.eql(u8, model_name, "gpt-4o")) has_gpt4o = true;
    }
    try std.testing.expect(has_gpt4o);

    const anthropic_models = Provider.anthropic.models();
    try std.testing.expect(anthropic_models.len > 0);
}

// ============================================================================
// ModelRegistry Tests
// ============================================================================

test "ModelRegistry.init creates empty registry" {
    const allocator = std.testing.allocator;
    var registry = try ModelRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.list().len);
}

test "ModelRegistry.register adds models" {
    const allocator = std.testing.allocator;
    var registry = try ModelRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "test-model",
        .display_name = "test-model",
        .max_output_tokens = 4096,
        .provider = "openai",
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_million_input = 2.0,
        .cost_per_million_output = 8.0,
    });

    try std.testing.expectEqual(@as(usize, 1), registry.list().len);
}

test "ModelRegistry.get finds registered models" {
    const allocator = std.testing.allocator;
    var registry = try ModelRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "find-me",
        .display_name = "find-me",
        .max_output_tokens = 4096,
        .provider = "openai",
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_million_input = 2.0,
        .cost_per_million_output = 8.0,
    });

    const found = registry.get("find-me");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("find-me", found.?.name);
}

test "ModelRegistry.get returns null for unknown models" {
    const allocator = std.testing.allocator;
    var registry = try ModelRegistry.init(allocator);
    defer registry.deinit();

    const found = registry.get("nonexistent-model");
    try std.testing.expect(found == null);
}

test "ModelRegistry.list returns all models" {
    const allocator = std.testing.allocator;
    var registry = try ModelRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "model-a",
        .display_name = "model-a",
        .max_output_tokens = 4096,
        .provider = "openai",
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_million_input = 1.0,
        .cost_per_million_output = 2.0,
    });

    try registry.register(.{
        .name = "model-b",
        .display_name = "model-b",
        .max_output_tokens = 4096,
        .provider = "anthropic",
        .context_window = 200000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_million_input = 3.0,
        .cost_per_million_output = 15.0,
    });

    const models_list = registry.list();
    try std.testing.expectEqual(@as(usize, 2), models_list.len);
}

test "ModelRegistry.route selects appropriate model" {
    const allocator = std.testing.allocator;
    var registry = try ModelRegistry.init(allocator);
    defer registry.deinit();

    // Register a function-calling model
    try registry.register(.{
        .name = "fc-model",
        .display_name = "fc-model",
        .max_output_tokens = 4096,
        .provider = "openai",
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_million_input = 1.0,
        .cost_per_million_output = 2.0,
    });

    // Register a streaming model
    try registry.register(.{
        .name = "stream-model",
        .display_name = "stream-model",
        .max_output_tokens = 4096,
        .provider = "openai",
        .context_window = 128000,
        .supports_function_calling = false,
        .supports_streaming = true,
        .cost_per_million_input = 0.5,
        .cost_per_million_output = 1.0,
    });

    // Route for function calling should return fc-model
    const fc_result = registry.route(.{
        .needs_function_calling = true,
        .needs_streaming = false,
    });
    try std.testing.expect(fc_result != null);
    try std.testing.expectEqualStrings("fc-model", fc_result.?.model.name);

    // Route for streaming should return stream-model
    const stream_result = registry.route(.{
        .needs_function_calling = false,
        .needs_streaming = true,
    });
    try std.testing.expect(stream_result != null);
    try std.testing.expectEqualStrings("stream-model", stream_result.?.model.name);
}

// ============================================================================
// Model Tests
// ============================================================================

test "Model struct has expected fields" {
    const model = ModelMetadata{
        .name = "test",
        .display_name = "Test Model",
        .max_output_tokens = 4096,
        .provider = "openai",
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_million_input = 2.0,
        .cost_per_million_output = 8.0,
    };

    try std.testing.expectEqualStrings("test", model.name);
    try std.testing.expectEqualStrings("openai", model.provider);
    try std.testing.expectEqual(@as(u32, 128000), model.context_window);
    try std.testing.expect(model.supports_function_calling);
    try std.testing.expect(model.supports_streaming);
}

test "TaskRequirements struct defaults" {
    const req = TaskRequirements{};
    try std.testing.expect(!req.needs_function_calling);
    try std.testing.expect(!req.needs_vision);
    try std.testing.expect(req.needs_streaming);
    try std.testing.expectEqual(@as(u32, 128000), req.min_context_window);
}

test "TaskRequirements struct with options" {
    const req = TaskRequirements{
        .needs_function_calling = true,
        .needs_vision = true,
        .budget_sensitive = true,
        .min_context_window = 200000,
    };
    try std.testing.expect(req.needs_function_calling);
    try std.testing.expect(req.needs_vision);
    try std.testing.expect(req.budget_sensitive);
    try std.testing.expectEqual(@as(u32, 200000), req.min_context_window);
}
