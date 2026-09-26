# AGENTS.md

## Project Context

knot3bot is a high-performance AI coding agent written in Zig. It is a rewrite of the Hermes Agent system from Python to Zig, leveraging Zig's compile-time features, zero-cost abstractions, and fine-grained memory management.

See `README.md` for project overview and `dev.md` for architecture design (in Chinese).

## Project Structure

```
knot3bot/
├── src/
│   ├── agent/          # ReAct loop, context compression, trajectory, skills
│   ├── memory/          # In-memory + SQLite backends
│   ├── providers/       # LLM provider adapters
│   ├── server/          # HTTP API server, rate limiter, circuit breaker
│   ├── adapters/        # ACP IDE protocol adapter
│   ├── tools/           # 44 built-in tools (default registry)
│   ├── gateway/         # Multi-platform message routing
│   ├── tui/             # libvaxis terminal UI
│   ├── shared/          # Logging, JSON utilities
│   ├── skills/          # Built-in skill packs (11 SKILL.md)
│   ├── option-skills/   # Optional skill packs (4 SKILL.md)
│   ├── tests.zig        # Unified test root (all suites, one binary)
│   └── main.zig         # CLI entry point
├── ui/                  # Dashboard web assets (HTMX + Alpine.js)
├── npm/                 # npm installer package
├── docs/                # Architecture and migration docs
├── vendor/sqlite3/      # SQLite C header (system libsqlite3 is linked)
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
- **FFI Strategy**: `addTranslateC` translates `vendor/sqlite3/sqlite3.h` (0.17 removed `@cImport`); system libsqlite3 is linked; pure Zig for JSON/HTTP

## Code Style

- Follow standard Zig naming: snake_case for functions/variables, PascalCase for types
- Use explicit error handling with try/catch; avoid catch unreachable
- Document public APIs with /// doc comments
- Prefer ArenaAllocator for per-request allocations

## Testing

```bash
# Run all tests (356 tests across one unified binary, src/tests.zig)
zig build test

# Per-suite breakdown
zig build test --summary all

# Run a single test while iterating
zig test src/validation.zig --test-filter "test_name"
```

Test files rooted outside their import directory (e.g. cross-directory
imports) must be listed in `src/tests.zig`; standalone `zig test <file>`
only works for files whose imports stay inside their own directory.

## Key Dependencies

| Dependency | Purpose | Integration |
|------------|---------|-------------|
| SQLite (system libsqlite3) | Session storage | `addTranslateC` on `vendor/sqlite3/sqlite3.h`, `linkSystemLibrary` |
| libvaxis 0.6.0 | Terminal UI | zig package (`b.dependency`), patched for 0.17 in `zig-pkg/` |
| uucode / zigimg | vaxis transitive deps | fetched into `zig-pkg/`, patched for 0.17 |

## Notes for Agents

- Zig 0.17.0 required
- Single binary output in zig-out/bin/knot3bot
- OpenAI-compatible REST API on HTTP server
- Multi-provider support: OpenAI, Anthropic, Kimi, MiniMax, ZAI, Bailian, Volcano
