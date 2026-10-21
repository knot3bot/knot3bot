# knot3bot

A high-performance AI coding agent in Zig. Single binary; links the system `libsqlite3` for session storage.

## Quick Start

```bash
# npm (recommended)
npm install -g knot3bot
knot3bot --help

# Build from source
zig build
./zig-out/bin/knot3bot --provider deepseek --model deepseek-chat

# Server mode with dashboard
DEEPSEEK_API_KEY=sk-xxx ./zig-out/bin/knot3bot --server --port 8080
# Open http://localhost:8080/dashboard
```

## Features

### Agent
- **ReAct loop** with streaming and non-streaming modes
- **Context compression** — automatic token budget management via LLM summarization
- **Smart model routing** — automatic provider/model selection
- **Trajectory recording** — JSONL audit logs for every agent run
- **Skill system** — built-in skills under `src/skills/`, plus `skills_list`, `skill_view`, `skill_manager`, and `skill_run`
- **Harness RSI** — off by default. One comparison round can adjust the prompt, checklist, retries, and visible tools, then keep the winner. See [Configuration](docs/configuration.md#harness-rsi)
- **Credential pool** — multi-key rotation (`*_API_KEY`, `*_API_KEY_2`...`_5`)
- **Memory** — in-memory + SQLite (FTS5 full-text search), conversation history persistence

### CLI / TUI
- **Layout** — session rail on wide terminals, transcript, `>` composer, and a workbar. The rail shows provider, model, session, tool count, and tokens
- **Slash commands** — `/help`, `/model`, `/config`, `/tools`, `/skills`, `/new`, `/quit` (`/h` and `/q` match help and quit)
- **Menus** — `/help`, `/model`, `/tools`, and `/skills` move with the arrow keys. Page Up, Page Down, Home, and End move inside `/model`, `/tools`, and `/skills`
- **Composer** — up/down recall what you sent in this process. Word motion, paste, and IME text go into the same line
- **One reply at a time** — the screen shows a spinner until the full answer arrives. Enter during a reply stores one follow-up. Ctrl-C quits without waiting
- **Setup wizard** — `--config` walks provider, API key, then model

### Web Dashboard
- **HTMX + Alpine.js + Tailwind CSS** — real-time chat interface
- **SSE streaming** — responses appear token-by-token
- **Provider/model switching** — select from 10 providers with latest models
- **Settings panel** — temperature, max tokens, system prompt, localStorage persistence
- **Metrics panel** — requests, latency, tokens, errors with 5s auto-refresh
- **Session management** — per-session message history

### Tools (37 in the default registry)
`shell`, `read_file`, `write_file`, `list_directory`, `grep`, `glob`, `calculator`,
`git`, `cron`, `http_request`, `web_fetch`, `web_search`, `web_extract`, `browser`, `spawn`,
`task_planner`, `diff`, `approval`, `url_safety`, `session_search`, `clarify`,
`env_passthrough`, `interrupt`, `todo`, `mcp`, `mcp_list_servers`, `checkpoint`,
`delegate`, `delegate_result`, `skill_self_improve`, `credential_files`, `code_execution`,
`memory`, `skills_list`, `skill_view`, `skill_manager`, `skill_run`

`code_execution` is registered and reports that the sandbox is not available in this build. `homeassistant`, `image_generation`, `send_message`, `tts`, `transcription`, `vision`, and `screen_capture` are not registered; calling them returns `not_available`.

### Providers (10)
| Provider | Models | Env Variable |
|----------|--------|-------------|
| OpenAI | gpt-5.5, gpt-5.5-mini, o5-mini, gpt-4o | `OPENAI_API_KEY` |
| DeepSeek | deepseek-v4-pro, deepseek-v4-flash, deepseek-chat | `DEEPSEEK_API_KEY` |
| Anthropic | claude-opus-4-7, claude-sonnet-4-6, claude-haiku-4-5 | `ANTHROPIC_API_KEY` |
| Bailian | qwen3.6-plus, qwen3.6-flash, qwen3.6-coder-plus | `BAILIAN_API_KEY` |
| Kimi | kimi-k2.5, kimi-k2-thinking | `KIMI_API_KEY` |
| MiniMax | MiniMax-M2.7, MiniMax-M2.5 | `MINIMAX_API_KEY` |
| Z.ai | glm-4.7, glm-4.7-flash | `ZAI_API_KEY` |
| OpenRouter | openai/gpt-4o (default), openai/gpt-5.1, google/gemini-2.5-pro | `OPENROUTER_API_KEY` |
| Volcano | doubao-seed-1-8-251228, doubao-pro-32k | `VOLCANO_API_KEY` |
| Tencent | hunyuan-lite (default), hunyuan-turbo-latest, hunyuan-t1-latest | `TENCENT_API_KEY` |

### Security
- Constant-time API key comparison (timing attack prevention)
- Shell command injection prevention (14 metacharacters, 9 dangerous prefixes)
- SSRF protection (hostname-based URL validation, symlink resolution)
- Path traversal prevention (null byte, `../`, absolute path blocking)
- HTTP security headers (X-Content-Type-Options, X-Frame-Options, HSTS)
- Sensitive env var filtering in sandboxed execution
- Skill safety levels (low/medium/high/critical) with approval gating

### Production
- **Rate limiter** — per-key token bucket with burst support and idle cleanup
- **Circuit breaker** — 3-state protection against provider cascading failures
- **Graceful shutdown** — connection draining with configurable timeout
- **Max connections** — configurable concurrent connection limit
- **Prometheus metrics** — `/metrics` endpoint with histogram, counters, gauges
- **Health checks** — `/health`, `/ready`, `/healthz` with provider connectivity verification
- **Docker** — multi-stage build, non-root user, healthcheck, resource limits
- **npm** — cross-platform binary installer with GitHub Releases fallback

## Architecture

```
src/
├── agent/           # ReAct loop, context compression, trajectory, harness RSI
├── memory/          # In-memory + SQLite (FTS5) backends
├── providers/       # OpenAI-compatible and Anthropic clients
├── server/          # HTTP API, rate limiter, circuit breaker
├── tools/           # Default tool registry
├── gateway/         # CLI and HTTP platform adapters
├── adapters/        # ACP over stdio (--acp)
├── tui/             # Interactive UI (libvaxis)
└── shared/          # JSON utilities, logger, process context
```

## CLI Commands

| Command | Description |
|---------|------------|
| `--config` | Configuration wizard (provider, key, model) |
| `/model` | Open the model menu |
| `/model <name>` | Switch model |
| `/config` | Show current configuration |
| `/tools` | List registered tools |
| `/skills` | Open the skills menu |
| `/new` | Start a new session |
| `/help`, `/h` | Show commands |
| `/quit`, `/q` | Exit |

`--provider` selects the provider before startup. Names: `openai`, `deepseek`, `kimi`, `minimax`, `zai`, `bailian`, `volcano`, `openrouter`, `tencent`, plus `-plan` variants where the provider defines them.

## HTTP API

OpenAI-compatible endpoints:

```bash
# Chat completion
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}]}'

# List models
curl http://localhost:8080/v1/models

# Health check
curl http://localhost:8080/health
```

## Development

Requires Zig 0.17.0.

```bash
zig build              # Build
zig build -Doptimize=safe
zig build test         # Tests imported by src/tests.zig
zig build benchmark    # Performance benchmarks
zig fmt src/           # Format code
```

## License

MIT
