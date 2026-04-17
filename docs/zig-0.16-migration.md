# Zig 0.15.2 → 0.16.0 Migration Guide for knot3bot

## Overview

Zig 0.16.0 introduces **I/O as an Interface** (`std.Io`), which is the largest breaking change affecting this codebase. Additionally, `std.posix` has been removed, environment variables are no longer global, and the build system has minor API changes.

## Breaking Changes Affecting This Codebase

### 1. Build System (`build.zig`)

| Old API | New API |
|---------|---------|
| `exe.linkSystemLibrary("name")` | `exe.root_module.linkSystemLibrary("name", .{})` |
| `exe.addIncludePath(...)` | `exe.root_module.addIncludePath(...)` |
| `exe.addLibraryPath(...)` | `exe.root_module.addLibraryPath(...)` |
| `b.addTest(.{ .root_module = mod })` | Same, but ensure `.target` is set on module |

**Package manifest (`build.zig.zon`) changes:**
- New required field: `.fingerprint = 0x...`
- Update `.minimum_zig_version = "0.16.0"`

### 2. `@cImport` Deprecation

`@cImport` is **deprecated** but still compiles. The recommended migration is to use `b.addTranslateC()` in `build.zig` and import the generated module. For this migration, we will keep `@cImport` working to minimize scope, as the build already succeeds past this point.

### 3. `std.posix` Removal

`std.posix` namespace has been removed. Platform-specific APIs moved to:
- `std.c` for POSIX-like systems (macOS, Linux with libc)
- `std.os.linux` for Linux direct syscalls
- `std.os.windows` for Windows

**Signal handling migration:**
```zig
// OLD (0.15.x)
const sa = std.posix.Sigaction{
    .handler = .{ .handler = handleSignal },
    .mask = std.posix.sigemptyset(),
    .flags = 0,
};
std.posix.sigaction(std.posix.SIG.INT, &sa, null);

// NEW (0.16.0)
var mask: std.c.sigset_t = undefined;
_ = std.c.sigemptyset(&mask);
const sa = std.c.Sigaction{
    .handler = .{ .handler = handleSignal },
    .mask = mask,
    .flags = 0,
};
_ = std.c.sigaction(std.c.SIG.INT, &sa, null);
```

Note: `handleSignal` must accept `std.c.SIG` instead of `c_int` on macOS.

**Other std.posix replacements:**
- `std.posix.getenv(key)` → Use `init.environ_map.get(key)` (via `std.process.Init`)
- `std.posix.kill(pid, sig)` → `std.c.kill(pid, sig)` (or `std.os.linux.kill`)
- `std.posix.realpath(path, &buf)` → `std.fs.path.resolve(allocator, &.{path})`

### 4. Process Arguments (`std.process`)

`std.process.argsWithAllocator()` is removed. The new pattern is to accept `std.process.Init` in `main()`:

```zig
// OLD
pub fn main() !void {
    var args = try std.process.argsWithAllocator(allocator);
}

// NEW
pub fn main(init: std.process.Init) !u8 {
    var args_iter = try init.args.initAllocator(init.gpa);
    // ... use args_iter
}
```

### 5. File System Operations (`std.fs.cwd()`)

`std.fs.cwd()` and most `std.fs` APIs are deprecated/removed. All file I/O now requires an `std.Io` instance:

```zig
// OLD
std.fs.cwd().writeFile(.{ .sub_path = path, .data = content });
std.fs.cwd().readFileAlloc(allocator, path, max);
std.fs.cwd().openDir(path, .{});
std.fs.cwd().makeDir(path);
std.fs.cwd().deleteFile(path);
std.fs.cwd().deleteTree(path);
std.fs.cwd().access(path, .{});

// NEW (requires std.Io instance)
try io.cwd().writeFile(path, content);
try io.cwd().readFileAlloc(allocator, path, max);
try io.cwd().openDir(path, .{});
try io.cwd().makeDir(path);
try io.cwd().deleteFile(path);
try io.cwd().deleteTree(path);
try io.cwd().access(path, .{});
```

### 6. Child Process API

`std.process.Child` still exists but some APIs may require `std.Io`. Need to verify per usage site.

### 7. HTTP Client

`std.http.Client` API may have changed to require `std.Io`. Need to verify in `providers/openai_compatible.zig`.

## Migration Strategy

Given the large surface area (~20+ files affected), we use a **pragmatic two-phase approach**:

### Phase 1: Get It Compiling

1. Change `main()` signature to `pub fn main(init: std.process.Init) !u8`
2. Extract `io` and `environ_map` from `init`
3. Pass `io` and `environ_map` down to top-level functions (`runCli`, `runServer`, etc.)
4. Replace `std.fs.cwd()` calls with `io.cwd()` equivalents
5. Replace `std.posix.getenv()` with `environ_map.get()`
6. Replace remaining `std.posix.*` calls
7. Update child process, HTTP client, and timer usages as needed

### Phase 2: Clean Up

1. Run `zig build test` and fix any remaining errors
2. Run `zig fmt` on all changed files
3. Verify benchmarks still work
4. Commit with clear message

## Files Requiring Changes

| File | Changes Needed |
|------|----------------|
| `build.zig` | `linkSystemLibrary`, `addIncludePath`, `addLibraryPath` → `root_module.*` |
| `build.zig.zon` | Add `fingerprint`, update `minimum_zig_version` |
| `vendor/sqlite3/build.zig.zon` | Add `fingerprint`, update `minimum_zig_version` |
| `src/main.zig` | `main` signature, args iteration, signal handling |
| `src/tools/web_search.zig` | `std.posix.getenv` → `environ_map` |
| `src/tools/spawn.zig` | `std.posix.kill` → `std.c.kill` |
| `src/tools/git.zig` | `std.posix.realpath` → `std.fs.path.resolve` |
| `src/tools/file_ops.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/tools/skills.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/tools/checkpoint.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/tools/delegate.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/tools/cron.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/tools/trajectory.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/config.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/agent/trajectory.zig` | `std.fs.cwd()` → `io.cwd()` |
| `src/providers/openai_compatible.zig` | `std.process.Child`, HTTP client |
| `src/tools/browser.zig` | `std.process.Child` |
| `src/tools/shell.zig` | `std.process.Child` |
| `src/tools/http_request.zig` | `std.process.Child` |
| `src/tools/web_fetch.zig` | `std.process.Child` |
| `src/tools/code_execution_tool.zig` | `std.process.Child` |
| `src/server/http_server.zig` | `std.net.StreamServer`, `std.http.Client` |

## Best Practices

1. **Use `init.gpa` for general-purpose allocations** instead of `std.heap.page_allocator` or `std.heap.c_allocator`
2. **Pass `io` explicitly** to functions that need filesystem/network access
3. **Use `init.environ_map`** for all environment variable lookups
4. **Keep `@cImport` for now** — migrating to `addTranslateC` can be done separately
5. **Test after every batch of changes** — `zig build` and `zig build test`
