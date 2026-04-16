//! Provider and model tests
const std = @import("std");
const providers = @import("providers/root.zig");
const Provider = providers.Provider;
const models = @import("models.zig");
const ModelRegistry = models.ModelRegistry;
const ModelRequirement = models.ModelRequirement;
const Model = models.Model;

// ============================================================================
// Provider Tests
// ============================================================================

test "Provider enum has expected values" {
    // Verify all expected providers exist
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(Provider.openai));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(Provider.anthropic));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(Provider.kimi));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(Provider.minimax));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(Provider.zai));
    try std.testing.expectEqual(@as(u8, 5), @intFromEnum(Provider.bailian));
    try std.testing.expectEqual(@as(u8, 6), @intFromEnum(Provider.volcano));
}

test "Provider.name returns expected string" {
    try std.testing.expectEqualStrings("openai", Provider.openai.name());
    try std.testing.expectEqualStrings("anthropic", Provider.anthropic.name());
    try std.testing.expectEqualStrings("kimi", Provider.kimi.name());
    try std.testing.expectEqualStrings("minimax", Provider.minimax.name());
    try std.testing.expectEqualStrings("zai", Provider.zai.name());
    try std.testing.expectEqualStrings("bailian", Provider.bailian.name());
    try std.testing.expectEqualStrings("volcano", Provider.volcano.name());
}

test "Provider.models returns non-empty list" {
    const openai_models = Provider.openai.models();
    try std.testing.expect(openai_models.len > 0);
    try std.testing.expect(std.mem.indexOf([]const u8, openai_models, "gpt-4o") != null);

    const anthropic_models = Provider.anthropic.models();
    try std.testing.expect(anthropic_models.len > 0);
}

// ============================================================================
// ModelRegistry Tests
// ============================================================================

test "ModelRegistry.init creates empty registry" {
    const allocator = std.testing.allocator;
    var registry = ModelRegistry.init(allocator);
    defer registry.deinit();

    try std.testing.expectEqual(@as(usize, 0), registry.count());
}

test "ModelRegistry.register adds models" {
    const allocator = std.testing.allocator;
    var registry = ModelRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "test-model",
        .provider = Provider.openai,
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_1k_input = 0.002,
        .cost_per_1k_output = 0.008,
    });

    try std.testing.expectEqual(@as(usize, 1), registry.count());
}

test "ModelRegistry.get finds registered models" {
    const allocator = std.testing.allocator;
    var registry = ModelRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "find-me",
        .provider = Provider.openai,
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_1k_input = 0.002,
        .cost_per_1k_output = 0.008,
    });

    const found = registry.get("find-me");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("find-me", found.?.name);
}

test "ModelRegistry.get returns null for unknown models" {
    const allocator = std.testing.allocator;
    var registry = ModelRegistry.init(allocator);
    defer registry.deinit();

    const found = registry.get("nonexistent-model");
    try std.testing.expect(found == null);
}

test "ModelRegistry.list returns all models" {
    const allocator = std.testing.allocator;
    var registry = ModelRegistry.init(allocator);
    defer registry.deinit();

    try registry.register(.{
        .name = "model-a",
        .provider = Provider.openai,
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_1k_input = 0.001,
        .cost_per_1k_output = 0.002,
    });

    try registry.register(.{
        .name = "model-b",
        .provider = Provider.anthropic,
        .context_window = 200000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_1k_input = 0.003,
        .cost_per_1k_output = 0.015,
    });

    const models_list = registry.list();
    try std.testing.expectEqual(@as(usize, 2), models_list.len);
}

test "ModelRegistry.route selects appropriate model" {
    const allocator = std.testing.allocator;
    var registry = ModelRegistry.init(allocator);
    defer registry.deinit();

    // Register a function-calling model
    try registry.register(.{
        .name = "fc-model",
        .provider = Provider.openai,
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_1k_input = 0.001,
        .cost_per_1k_output = 0.002,
    });

    // Register a streaming model
    try registry.register(.{
        .name = "stream-model",
        .provider = Provider.openai,
        .context_window = 128000,
        .supports_function_calling = false,
        .supports_streaming = true,
        .cost_per_1k_input = 0.0005,
        .cost_per_1k_output = 0.001,
    });

    // Route for function calling should return fc-model
    const fc_result = registry.route(.{
        .needs_function_calling = true,
        .needs_streaming = false,
    });
    try std.testing.expect(fc_result != null);
    try std.testing.expectEqualStrings("fc-model", fc_result.?.name);

    // Route for streaming should return stream-model
    const stream_result = registry.route(.{
        .needs_function_calling = false,
        .needs_streaming = true,
    });
    try std.testing.expect(stream_result != null);
    try std.testing.expectEqualStrings("stream-model", stream_result.?.name);
}

// ============================================================================
// Model Tests
// ============================================================================

test "Model struct has expected fields" {
    const model = Model{
        .name = "test",
        .provider = Provider.openai,
        .context_window = 128000,
        .supports_function_calling = true,
        .supports_streaming = true,
        .cost_per_1k_input = 0.002,
        .cost_per_1k_output = 0.008,
    };

    try std.testing.expectEqualStrings("test", model.name);
    try std.testing.expectEqual(Provider.openai, model.provider);
    try std.testing.expectEqual(@as(u32, 128000), model.context_window);
    try std.testing.expect(model.supports_function_calling);
    try std.testing.expect(model.supports_streaming);
}

test "ModelRequirement struct defaults" {
    const req = ModelRequirement{};
    try std.testing.expect(!req.needs_function_calling);
    try std.testing.expect(!req.needs_streaming);
    try std.testing.expect(!req.prefer_low_cost);
    try std.testing.expect(!req.prefer_low_latency);
    try std.testing.expect(!req.prefer_large_context);
}

test "ModelRequirement struct with options" {
    const req = ModelRequirement{
        .needs_function_calling = true,
        .needs_streaming = true,
        .prefer_low_cost = true,
        .prefer_large_context = true,
    };
    try std.testing.expect(req.needs_function_calling);
    try std.testing.expect(req.needs_streaming);
    try std.testing.expect(req.prefer_low_cost);
    try std.testing.expect(req.prefer_large_context);
}
