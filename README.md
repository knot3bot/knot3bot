# knot3bot

A high-performance AI coding agent written in Zig. Single binary, zero runtime dependencies, blazing fast.

knot3bot is a rewrite of the Hermes Agent system in [Zig](https://ziglang.org/), leveraging compile-time features, zero-cost abstractions, and fine-grained memory management to build a lean, production-ready AI agent.

## Features

- **ReAct Agent Loop** — Reasoning + Acting pattern for robust tool use
- **Multi-Provider Support** — OpenAI, Anthropic, Kimi, MiniMax, ZAI, Bailian, Volcano
- **Tool Registry** — 30+ built-in tools (file ops, shell, git, browser, MCP, cron, etc.)
- **Memory System** — In-memory + SQLite backends, automatic session persistence
- **Context Compression** — Automatic token budget management with LLM-based summarization
- **Trajectory Recording** — JSONL audit logs of agent reasoning traces
- **Smart Model Routing** — Automatic provider/model selection based on task complexity
- **Anthropic Tool Support** — Native tool-use API with OpenAI-compatible responses
- **HTTP Server** — OpenAI-compatible REST API (`/v1/chat/completions`, `/v1/responses`)
- **ACP Adapter** — IDE integration via Agent Client Protocol (stdio JSON-RPC)
- **Credential Pool** — Automatic key rotation across multiple API keys
- **Production-Grade HTTP** — Rate limiting, circuit breakers, Prometheus metrics

## Quick Start

### Prerequisites

- Zig 0.15+
- SQLite (optional, for persistent memory)

### Build

```bash
zig build
```

### Run

```bash
# Interactive CLI mode
./zig-out/bin/knot3bot

# With a specific provider
BAILIAN_API_KEY=xxx ./zig-out/bin/knot3bot --provider bailian

# HTTP server mode
./zig-out/bin/knot3bot --server --port 8080
```

### Docker

```bash
docker compose up
```

## Architecture

```
src/
├── agent/          # ReAct loop, context compression, trajectory
├── memory/         # In-memory + SQLite backends
├── providers/      # LLM provider adapters (OpenAI, Anthropic, etc.)
├── server/         # HTTP API server
├── adapters/       # ACP IDE protocol adapter
├── tools/          # Tool implementations (30+ tools)
├── shared/         # Logging, JSON utilities
└── main.zig       # CLI entry point
```

### Key Design Decisions

- **Compile-time tool registration** via Zig's comptime — no reflection overhead
- **Arena allocators** for request-scoped memory, GPA for long-lived state
- **Static dispatch** throughout — no virtual function tables
- **SQLite via C ABI** — proven durability, single file storage
- **Pure Zig JSON** — no external dependencies

## Configuration

knot3bot looks for config in this order:
1. `KNOT3BOT_CONFIG` env var
2. `~/.knot3bot/config.json`
3. `./knot3bot.json`

See `.env.example` for supported environment variables.

### Supported Providers

| Provider   | Model                          | Env Variable      |
|------------|--------------------------------|-------------------|
| OpenAI     | gpt-4o, gpt-4, gpt-3.5-turbo   | `OPENAI_API_KEY` |
| Anthropic  | claude-3-5-sonnet, claude-3-opus | `ANTHROPIC_API_KEY` |
| Kimi       | moonshot-v1-8k                  | `KIMI_API_KEY`    |
| MiniMax    | abab6-chat                      | `MINIMAX_API_KEY` |
| ZAI        | glm-4                           | `ZAI_API_KEY`     |
| Bailian    | qwen-plus                       | `BAILIAN_API_KEY` |
| Volcano    | doubao-pro                       | `VOLCANO_API_KEY` |

## Development

```bash
# Build
zig build

# Test
zig build test

# Format
zig fmt src/
```

### Testing with Docker

```bash
./scripts/docker-test.sh
```

## Documentation

Full documentation available in [`docs/`](docs/):

- [Installation](docs/installation.md)
- [Quick Start](docs/quickstart.md)
- [CLI Reference](docs/cli.md)
- [Configuration](docs/configuration.md)
- [HTTP API](docs/api.md)
- [Tools Reference](docs/tools.md)
- [Architecture](docs/architecture.md)

## Contributing


Contributions welcome. Please read existing code style (Zig standard, snake_case functions, PascalCase types). Run `zig build test` before submitting.

## License

MIT License — see [LICENSE](LICENSE) for details.
