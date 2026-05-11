# knot3bot

High-performance AI coding agent in Zig. Single binary, zero runtime dependencies.

## Quick Start

```bash
npm install -g knot3bot
knot3bot --help
```

Or run without installing:

```bash
npx knot3bot --help
```

## Requirements

- Node.js >= 16
- An API key from a supported provider (OpenAI, Anthropic, Bailian, Kimi, etc.)

## Setup

```bash
# Interactive configuration wizard
knot3bot --config

# Or set an API key directly
export OPENAI_API_KEY="sk-..."
knot3bot --provider openai --model gpt-4o
```

## CLI Commands

| Command | Description |
|---------|-------------|
| `/help` | Show all commands |
| `/model [name]` | Switch or show models |
| `/config` | Show current configuration |
| `/tools` | Show tool state |
| `/skills` | Show installed skills |
| `/new` | Start new conversation |
| `/quit` | Exit |

## Server Mode

```bash
knot3bot --server --port 8080
```

Then use any OpenAI-compatible client:

```bash
curl http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer sk-..." \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}]}'
```

## Supported Platforms

| Platform | Architecture | Status |
|----------|-------------|--------|
| macOS | x64, arm64 | ✓ |
| Linux | x64, arm64 (musl) | ✓ |

## Links

- [GitHub Repository](https://github.com/knot3bot/knot3bot)
- [Full Documentation](https://github.com/knot3bot/knot3bot/tree/master/docs)
