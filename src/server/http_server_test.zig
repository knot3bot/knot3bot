const std = @import("std");
const AuthConfig = @import("http_server.zig").AuthConfig;

test "AuthConfig.validateKey - accepts valid key" {
    const config = AuthConfig{
        .require_auth = true,
        .api_keys = &.{ "test-key-1", "test-key-2" },
        .allowed_origins = &.{},
    };

    try std.testing.expect(config.validateKey("test-key-1"));
    try std.testing.expect(config.validateKey("test-key-2"));
}

test "AuthConfig.validateKey - rejects invalid key" {
    const config = AuthConfig{
        .require_auth = true,
        .api_keys = &.{"test-key"},
        .allowed_origins = &.{},
    };

    try std.testing.expect(!config.validateKey("wrong-key"));
    try std.testing.expect(!config.validateKey(""));
    try std.testing.expect(!config.validateKey("test"));
}

test "AuthConfig.validateOrigin - accepts valid origins" {
    const config = AuthConfig{
        .require_auth = true,
        .api_keys = &.{},
        .allowed_origins = &.{ "https://example.com", "https://api.example.com" },
    };

    try std.testing.expect(config.validateOrigin("https://example.com"));
    try std.testing.expect(config.validateOrigin("https://api.example.com"));
}

test "AuthConfig.validateOrigin - accepts wildcard" {
    const config = AuthConfig{
        .require_auth = true,
        .api_keys = &.{},
        .allowed_origins = &.{"*"},
    };

    try std.testing.expect(config.validateOrigin("https://any-site.com"));
    try std.testing.expect(config.validateOrigin("http://localhost:3000"));
}

test "AuthConfig.validateOrigin - rejects unauthorized origins" {
    const config = AuthConfig{
        .require_auth = true,
        .api_keys = &.{},
        .allowed_origins = &.{"https://allowed.com"},
    };

    try std.testing.expect(!config.validateOrigin("https://other.com"));
}

test "AuthConfig.validateOrigin - empty origins allows all" {
    const config = AuthConfig{
        .require_auth = true,
        .api_keys = &.{},
        .allowed_origins = &.{},
    };

    // Empty origins should allow all
    try std.testing.expect(config.validateOrigin("https://any-site.com"));
}
