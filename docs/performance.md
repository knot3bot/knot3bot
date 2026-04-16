# Performance

This document covers performance characteristics, benchmarks, and optimization guidelines for knot3bot.

## Benchmark Results

Run benchmarks with:
```bash
zig build benchmark
```

### Core Data Structures

| Operation | Performance | Notes |
|-----------|-------------|-------|
| TokenBudget.consume() | ~3 ns/op | 10K iterations |
| IterationBudget.tick() | ~4 ns/op | 1M iterations |
| UsageStats.update() | ~3 ns/op | 10K iterations |
| ReActStep.toJSON() | ~99 μs/op | JSON serialization |

### Tool Operations

| Operation | Performance | Notes |
|-----------|-------------|-------|
| ToolResult.ok() | ~4 ns/op | 100K iterations |
| ToolResult.fail() | ~4 ns/op | 100K iterations |
| JSON parsing | ~20 μs/op | Simple object parse |

### Memory Operations

| Operation | Performance | Notes |
|-----------|-------------|-------|
| String duplication (50 bytes) | ~2 μs/op | Includes allocation |
| Arena allocation (3 allocs) | ~20 μs/op | Per-iteration overhead |

## Binary Size

Release builds with `-Doptimize=ReleaseSmall`:

| Platform | Architecture | Size |
|----------|-------------|------|
| Linux | x86_64-musl | ~2.5 MB |
| Linux | aarch64-musl | ~2.5 MB |
| macOS | x86_64-gnu | ~2.3 MB |
| macOS | aarch64-gnu | ~2.3 MB |

## Startup Time

Cold start (no cache):
- CLI mode: ~50ms
- HTTP server mode: ~80ms

Warm start (with cached tools):
- CLI mode: ~10ms
- HTTP server mode: ~15ms

## Memory Usage

Typical memory usage per request:

| Component | Memory |
|-----------|--------|
| Agent state | ~50 KB |
| Tool registry (30 tools) | ~500 KB |
| Arena allocator (typical request) | ~100 KB - 2 MB |
| LLM response buffer | ~10 KB - 100 KB |

Peak memory usage depends on:
- Context size (number of messages)
- Tool response sizes
- Streaming buffer requirements

## HTTP Server Performance

| Metric | Value |
|--------|-------|
| Max request size | 1 MB |
| Rate limit (default) | 100 req/min per key |
| Circuit breaker threshold | 5 failures |
| Circuit breaker reset | 30 seconds |

### Latency

| Endpoint | P50 | P95 | P99 |
|----------|-----|------|-----|
| /health | <1ms | <2ms | <5ms |
| /v1/chat/completions | Depends on LLM | - | - |

## Optimization Tips

### 1. Reduce Binary Size
```bash
zig build -Doptimize=ReleaseSmall
```

### 2. Disable Unused Features
Build without SQLite if not needed:
```bash
zig build -Denable-sqlite=false
```

### 3. Memory Pooling
Use arena allocators for request-scoped memory to reduce allocations:
```zig
var arena = std.heap.ArenaAllocator.init(gpa.allocator());
defer arena.deinit();
const allocator = arena.allocator();
```

### 4. Streaming Responses
Enable streaming to reduce perceived latency:
```bash
./knot3bot --stream
```

### 5. Model Selection
Choose smaller models for simple tasks:
- Simple queries: `gpt-3.5-turbo` or `glm-4`
- Complex reasoning: `gpt-4o` or `claude-3-5-sonnet`

## Profiling

### CPU Profiling
Use Zig's built-in profiler or `perf`:
```bash
perf record -g ./zig-out/bin/knot3bot --server
perf report
```

### Memory Profiling
Run with debug allocator:
```zig
var gpa = std.heap.GeneralPurposeAllocator(.{ .verbose_log = true }){};
```

## Known Performance Characteristics

1. **Cold start overhead**: Tool registration happens at startup
2. **JSON parsing**: Pure Zig JSON is slower than native bindings but has no dependencies
3. **SQLite I/O**: Blocking I/O for session storage (use in-memory for higher throughput)
4. **TLS**: HTTPS requests use system TLS, which may have verification overhead

## Future Optimizations

- [ ] WASM plugin system for hot-loading tools
- [ ] Connection pooling for LLM providers
- [ ] Async I/O throughout the HTTP server
- [ ] Shared memory for multi-process deployments
- [ ] SIMD-accelerated tokenization
