//! Tests for tool factory

const std = @import("std");
const factory = @import("factory.zig");

test "createDefaultRegistry has expected tool count" {
    const registry = try factory.createDefaultRegistry(std.testing.allocator, "/tmp");
    defer registry.deinit();
    const tools = registry.list();
    try std.testing.expect(tools.len >= 20); // At least 20 core tools
    try std.testing.expect(tools.len <= 50); // Not too many
}

test "createFullRegistry has more tools than default" {
    const default_reg = try factory.createDefaultRegistry(std.testing.allocator, "/tmp");
    defer default_reg.deinit();
    const full_reg = try factory.createFullRegistry(std.testing.allocator, "/tmp");
    defer full_reg.deinit();
    try std.testing.expect(full_reg.list().len >= default_reg.list().len);
}
