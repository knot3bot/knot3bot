# AGENTS.md

## Project Context

knot3bot is a high-performance AI coding agent written in Zig. It is a rewrite of the Hermes Agent system from Python to Zig, leveraging Zig's compile-time features, zero-cost abstractions, and fine-grained memory management.

See `README.md` for project overview and `dev.md` for architecture design (in Chinese).

## Project Structure

```
knot3bot/
├── src/
│   ├── agent/          # ReAct loop, context compression, trajectory
│   ├── memory/          # In-memory + SQLite backends
│   ├── providers/       # LLM provider adapters
│   ├── server/          # HTTP API server
│   ├── adapters/        # ACP IDE protocol adapter
│   ├── tools/           # 30+ built-in tools
│   ├── shared/          # Logging, JSON utilities
│   └── main.zig         # CLI entry point
├── vendor/sqlite3/      # SQLite C source
├── build.zig
├── build.zig.zon
├── README.md
├── LICENSE
└── AGENTS.md
```

## Development Commands

| Command | Purpose |
|---------|---------|
| `zig build` | Build the project |
| `zig build run` | Build and run |
| `zig build test` | Run tests |
| `zig fmt src/` | Format all source files |
| `zig build --release=fast` | Optimized release build |

## Architecture Decisions

- **Memory Management**: ArenaAllocator for request-scoped allocations, GeneralPurposeAllocator for long-lived state
- **Concurrency**: std.Thread thread pools
- **Tool Registry**: comptime tool registration and static dispatch
- **FFI Strategy**: @cImport for SQLite; pure Zig for JSON/HTTP

## Code Style

- Follow standard Zig naming: snake_case for functions/variables, PascalCase for types
- Use explicit error handling with try/catch; avoid catch unreachable
- Document public APIs with /// doc comments
- Prefer ArenaAllocator for per-request allocations

## Testing

```bash
# Run all tests
zig build test

# Run specific test
zig test src/module.zig --test-filter "test_name"
```

## Key Dependencies

| Dependency | Purpose | Integration |
|------------|---------|-------------|
| SQLite | Session storage | @cImport via C ABI |
| websocket | WebSocket support | @cImport |
| wasm3 | WASM runtime | @cImport |

## Notes for Agents

- Zig 0.15.2 required
- Single binary output in zig-out/bin/knot3bot
- OpenAI-compatible REST API on HTTP server
- Multi-provider support: OpenAI, Anthropic, Kimi, MiniMax, ZAI, Bailian, Volcano
