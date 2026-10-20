# Zig 0.16.0 → 0.17.0 Migration Guide for knot3bot

## Overview

Zig 0.17.0 introduces several breaking changes affecting this codebase. The most significant are:

- `std.meta.Int` / `std.meta.Tuple` removed in favor of `@Int` / `@Tuple` builtins
- `@cImport` removed — must use `b.addTranslateC()` in build.zig
- `**` (array multiplication) operator removed — use `@splat()` instead
- `std.Io.File.writer()` API signature change (now requires `buffer` parameter)
- Formatting rules for binary operators tightened

## Breaking Changes Affecting This Codebase

### 1. `std.meta.Int` → `@Int`

`std.meta.Int` has been removed. Use the `@Int` builtin instead.

| Old | New |
|-----|-----|
| `std.meta.Int(.unsigned, N)` | `@Int(.unsigned, N)` |
| `std.meta.Int(.signed, N)` | `@Int(.signed, N)` |
| `std.meta.Int(signedness, N)` | `@Int(signedness, N)` |

**Affected files (all in zig-pkg dependencies):**
- `zig-pkg/uucode-*/src/multi_slice.zig`
- `zig-pkg/uucode-*/src/generate.zig`
- `zig-pkg/uucode-*/src/storage.zig` (2 occurrences)
- `zig-pkg/zigimg-*/src/formats/tga.zig` (2 occurrences)
- `zig-pkg/zigimg-*/src/formats/pam.zig`
- `zig-pkg/zigimg-*/src/io.zig` (3 occurrences)

### 2. `@cImport` → `b.addTranslateC()`

`@cImport` has been completely removed. C headers must be translated at build time.

**build.zig:**
```zig
// Add after linking SQLite:
const sqlite3_translate = b.addTranslateC(.{
    .root_source_file = b.path("vendor/sqlite3/sqlite3.h"),
    .target = target,
    .optimize = optimize,
});
const sqlite3_mod = sqlite3_translate.createModule();
mod.addImport("sqlite3_c", sqlite3_mod);
exe.root_module.addImport("sqlite3_c", sqlite3_mod);
```

**src/memory/sqlite_impl.zig:**
```zig
// OLD
const c = @cImport(@cInclude("sqlite3.h"));

// NEW
const c = @import("sqlite3_c");
```

### 3. `**` (Array Multiplication) → `@splat()`

The `**` operator for array multiplication has been removed ([issue #24738](https://github.com/ziglang/zig/issues/24738)).

| Old | New |
|-----|-----|
| `[_]u8{0} ** 4096` | `@splat(0)` (with explicit type annotation: `[4096]u8 = @splat(0)`) |
| `.{0}**8` | `@splat(0)` |
| `"text" ** 10` | String concatenation via `++` or comptime loop |

**Affected files:**
- `src/tui/vaxis_tui.zig` (3 occurrences): array initialization → `@splat(0)`
- `src/server/http_server.zig`: struct array init → `@splat(0)`
- `src/agent/context_compressor_test.zig` (2 occurrences): string multiply → `++` concatenation
- `zig-pkg/zigimg-*/src/compressions/deflate/Lookup.zig` (2 occurrences)
- `zig-pkg/zigimg-*/src/compressions/deflate/huffman_encoder.zig`
- `zig-pkg/zigimg-*/src/formats/jpeg/writer.zig`
- `zig-pkg/zigimg-*/src/io.zig`

### 4. `std.Io.File.writer()` API Change

`File.writer()` now requires both `io` and `buffer` parameters:

```zig
// OLD
std.Io.File.stderr().writer(io)

// NEW
std.Io.File.stderr().writer(io, &log_buf)
```

Additionally, `File.Writer` is now a distinct type from `Io.Writer`. Use `.interface` to get the generic `Io.Writer`:

```zig
const file_writer = std.Io.File.stderr().writer(io, &log_buf);
json_logger.init(file_writer.interface);
```

**Affected file:** `src/main.zig`

### 5. Binary Operator Formatting

Zig 0.17 enforces symmetric whitespace around binary operators. The `**` operator was particularly affected before its removal.

## Package Manifest Changes

Update `.minimum_zig_version` in all `build.zig.zon` files:

- `build.zig.zon`: `"0.16.0"` → `"0.17.0"`
- `vendor/sqlite3/build.zig.zon`: `"0.16.0"` → `"0.17.0"`

## Files Changed Summary

| File | Change |
|------|--------|
| `build.zig` | Added `addTranslateC` for SQLite; import `sqlite3_c` to mod + exe |
| `build.zig.zon` | Updated `minimum_zig_version` to `0.17.0` |
| `vendor/sqlite3/build.zig.zon` | Updated `minimum_zig_version` to `0.17.0` |
| `src/main.zig` | Updated `writer()` call with `io` + buffer; use `.interface` |
| `src/memory/sqlite_impl.zig` | `@cImport` → `@import("sqlite3_c")` |
| `src/tui/vaxis_tui.zig` | `[_]u8{0} ** N` → `@splat(0)` (3 occurrences) |
| `src/server/http_server.zig` | `.{0}**8` → `@splat(0)` |
| `src/agent/context_compressor_test.zig` | String `**` → `++` (2 occurrences) |
| `zig-pkg/uucode-*/` | `std.meta.Int` → `@Int` (4 occurrences) |
| `zig-pkg/zigimg-*/` | `std.meta.Int` → `@Int` (6 occurrences); `**` → `@splat` (4 occurrences) |

## Verification

```bash
# Build
zig build                          # succeeds

# Tests
zig build test                     # All 356 tests pass via the unified root
                                   # (src/tests.zig); use --summary all for
                                   # the per-suite breakdown
```

Note: later 0.17.0-dev snapshots (e.g. dev.2131) additionally required
porting the vendored packages to the flattened `@typeInfo` API and
replacing `Build.args` — see commit history ("adapt build system to Zig
0.17.0-dev.2131 toolchain").
