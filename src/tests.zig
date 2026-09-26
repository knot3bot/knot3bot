//! Unified test root — `zig build test` compiles this file as a single test
//! binary covering the full suite: inline tests of individual source files
//! plus every dedicated *_test.zig module.
//!
//! Rooting the test module at src/ (instead of each file's own directory)
//! also unblocks cross-directory imports in test files, e.g.
//! `../shared/context.zig` from src/tools/*. Test files that live outside
//! their import root, such as agent/context_compressor_test.zig importing
//! "agent/...", only resolve with this unified layout.

const std = @import("std");

test {
    // Inline tests in regular source files
    _ = @import("validation.zig");
    _ = @import("cli.zig");
    _ = @import("server/circuit_breaker.zig");
    _ = @import("server/rate_limiter.zig");

    // Dedicated test suites
    _ = @import("architecture_test.zig");
    _ = @import("e2e_smoke_test.zig");
    _ = @import("integration_test.zig");
    _ = @import("memory_test.zig");
    _ = @import("memory_stress_test.zig");
    _ = @import("validation_test.zig");
    _ = @import("agent/agent_test.zig");
    _ = @import("agent/agent_unit_test.zig");
    _ = @import("agent/context_compressor_test.zig");
    _ = @import("providers/providers_interface_test.zig");
    _ = @import("providers/providers_test.zig");
    _ = @import("server/http_server_test.zig");
    _ = @import("server/server_test.zig");
    _ = @import("shared/json_test.zig");
    _ = @import("tools/factory_test.zig");
    _ = @import("tools/mcp_test.zig");

    // Keep the ACP adapter compiled and analyzed (it is wired via --acp).
    comptime {
        std.testing.refAllDecls(@import("adapters/acp_adapter.zig"));
    }
    _ = @import("tools/mcp_test.zig");
    _ = @import("tools/shell_test.zig");
    _ = @import("tools/tools_test.zig");
}
