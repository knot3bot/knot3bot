//! Module root for stub-tool honesty tests.
//! Zig 0.17 rejects `zig test src/tools/stub_honesty_test.zig` because that
//! file's module root is `src/tools` and tool imports reach `src/shared`.
//! Importing the suite from `src/` keeps those paths inside the module.
comptime {
    _ = @import("tools/stub_honesty_test.zig");
}
