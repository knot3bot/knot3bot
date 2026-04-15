# Configuration

knot3bot can be configured via environment variables, CLI flags, or config files.

## Configuration Precedence

Configuration is loaded in this order (later overrides earlier):

1. Default values
2. Config file (`~/.knot3bot/config.json` or `./knot3bot.json`)
3. Environment variables
4. CLI flags

## Environment Variables

### LLM Providers

At least one API key is required:

```bash
# OpenAI
export OPENAI_API_KEY=sk-...

# Anthropic
export ANTHROPIC_API_KEY=sk-ant-...

# Kimi (Moonshot AI)
export KIMI_API_KEY=...

# MiniMax
export MINIMAX_API_KEY=...

# ZAI (01.AI)
export ZAI_API_KEY=...

# Bailian (Alibaba Cloud Qwen)
export BAILIAN_API_KEY=...

# Volcano (ByteDance)
export VOLCANO_API_KEY=...
```

### Application Settings

```bash
# Server port (default: 8080)
export PORT=8080

# Debug logging (default: false)
export DEBUG=false

# Workspace directory (default: /tmp)
export HERMES_WORKSPACE=/path/to/workspace

# Config file path (optional)
export KNOT3BOT_CONFIG=/path/to/config.json
```

## Config File

Create `~/.knot3bot/config.json` or `./knot3bot.json`:

```json
{
  "api": {
    "key": "sk-...",
    "base": "https://api.openai.com/v1",
    "model": "gpt-4"
  },
  "memory": {
    "backend": "sqlite",
    "db_path": "/path/to/memory.db"
  },
  "server": {
    "port": 8080,
    "host": "0.0.0.0"
  },
  "logging": {
    "level": "info",
    "file": "/var/log/knot3bot.log"
  },
  "behavior": {
    "max_iterations": 10,
    "timeout_seconds": 60
  }
}
```

## CLI Flags

```bash
knot3bot [options]

Options:
  --help, -h              Show this help message
  --db-path <path>        SQLite database path (default: in-memory)
  --session <id>          Session ID (default: default)
  --model <name>          LLM model name
  --provider <name>       LLM provider: openai, anthropic, kimi, minimax, zai, bailian, volcano
  --max-iterations <n>    Max ReAct iterations (default: 10)
  --server                Run in HTTP server mode
  --port <port>           Server port (default: 8080)
```

## Provider Configuration

### OpenAI

```bash
export OPENAI_API_KEY=sk-...
```

| Model | Description |
|-------|-------------|
| `gpt-4o` | Latest GPT-4 Omni (default) |
| `gpt-4-turbo` | GPT-4 Turbo |
| `gpt-4` | GPT-4 |
| `gpt-3.5-turbo` | GPT-3.5 Turbo |

### Anthropic

```bash
export ANTHROPIC_API_KEY=sk-ant-...
```

| Model | Description |
|-------|-------------|
| `claude-3-5-sonnet-20241022` | Claude 3.5 Sonnet (default) |
| `claude-3-opus-20240229` | Claude 3 Opus |
| `claude-3-sonnet-20240229` | Claude 3 Sonnet |
| `claude-3-haiku-20240307` | Claude 3 Haiku |

### Bailian (Qwen)

```bash
export BAILIAN_API_KEY=...
```

| Model | Description |
|-------|-------------|
| `qwen-plus` | Qwen Plus (default) |
| `qwen-turbo` | Qwen Turbo |
| `qwen-max` | Qwen Max |

## Memory Configuration

### In-Memory (Default)

Sessions are not persisted between restarts:

```bash
# No --db-path flag = in-memory
knot3bot
```

### SQLite Persistence

```bash
# Save to file
knot3bot --db-path ./memory.db

# Save to default location
mkdir -p ~/.knot3bot
knot3bot --db-path ~/.knot3bot/memory.db
```

## Logging

Configure log level via environment or config:

```bash
# Via environment
export DEBUG=true  # or ZIG_LOG_LEVEL=debug

# Via config
{
  "logging": {
    "level": "debug",
    "file": "/var/log/knot3bot.log"
  }
}
```

Log levels: `debug`, `info`, `warn`, `error`

## Next Steps

- [CLI Reference](cli.md) — Complete CLI documentation
- [HTTP API](api.md) — Server mode configuration
