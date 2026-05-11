# knot3bot

A high-performance AI coding agent in Zig. Single binary, zero runtime dependencies.

## Quick Start

```bash
# npm (recommended)
npm install -g knot3bot
knot3bot --help

# Build from source
zig build
./zig-out/bin/knot3bot --provider deepseek --model deepseek-v4-pro

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
- **Skill system** — 5 default skills (plan/debug/research/review/shell-safety) with safety levels
- **Credential pool** — multi-key rotation (`*_API_KEY`, `*_API_KEY_2`...`_5`)
- **Memory** — in-memory + SQLite (FTS5 full-text search), conversation history persistence

### CLI / TUI
- **Slash commands**: `/help`, `/setup`, `/model`, `/provider`, `/config`, `/tools`, `/skills`, `/new`, `/quit`
- **Interactive menus** — arrow-key navigation for model/tool/skills selection
- **Command history** — up/down arrow recall of last 100 commands
- **Rich prompt** — shows current model/provider/session
- **Setup wizard** — 3-step interactive configuration (provider → API key → model)

### Web Dashboard
- **HTMX + Alpine.js + Tailwind CSS** — real-time chat interface
- **SSE streaming** — responses appear token-by-token
- **Provider/model switching** — select from 10 providers with latest models
- **Settings panel** — temperature, max tokens, system prompt, localStorage persistence
- **Metrics panel** — requests, latency, tokens, errors with 5s auto-refresh
- **Session management** — per-session message history

### Tools (30)
`shell`, `read_file`, `write_file`, `list_directory`, `grep`, `glob`, `todo`, `calculator`,
`git`, `cron`, `http_request`, `web_fetch`, `web_search`, `web_extract`, `browser`, `spawn`,
`task_planner`, `diff`, `approval`, `url_safety`, `session_search`, `homeassistant`,
`image_generation`, `send_message`, `transcription`, `tts`, `vision`, `screen_capture`,
`clarify`, `env_passthrough`

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
| OpenRouter | gpt-5.5, claude-opus-4-7, gemini-2.5-pro | `OPENROUTER_API_KEY` |
| Volcano | doubao-seed, doubao-pro | `VOLCANO_API_KEY` |
| Tencent | hunyuan-turbo, hunyuan-t1 | `TENCENT_API_KEY` |

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
├── llm/             # Provider adapters (OpenAI-compatible, Anthropic)
├── interface/       # CLI, Gateway, ACP IDE adapter
├── intelligence/    # Skills, memory, cron scheduler
├── security/        # Validation, URL safety, approval
├── agent/           # ReAct loop, context compression, trajectory
├── memory/          # In-memory + SQLite (FTS5) backends
├── providers/       # LLM client implementations
├── server/          # HTTP API server + rate limiter + circuit breaker
├── tools/           # 30 tool implementations
├── gateway/         # Multi-platform message routing
└── shared/          # JSON utilities, logger, context
```

## CLI Commands

| Command | Description |
|---------|------------|
| `/setup` | Interactive configuration wizard (provider → key → model) |
| `/model [name]` | Switch model or show interactive selector |
| `/provider` | Switch AI provider |
| `/config` | Show current configuration |
| `/tools` | Show tool state, enable/disable tools |
| `/skills` | Show and activate skills |
| `/new` | Start new conversation |
| `/help` | Show all commands |
| `/quit` | Exit |

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

```bash
zig build              # Build (default: ReleaseSafe)
zig build test         # Run tests (79 tests)
zig build benchmark    # Performance benchmarks
zig fmt src/           # Format code
```

## License

MIT
