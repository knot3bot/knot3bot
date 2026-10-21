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
  --enable-harness-rsi    Enable harness RSI (default: off)
  --harness-tag <tag>     Harness task tag (default: general)
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

## Harness RSI

Off unless `--enable-harness-rsi` is passed (or `AgentConfig.enable_harness_rsi` is set to `true`). `--harness-tag <tag>` sets the task tag; the default is `general`. The same flags apply to `--server`.

| Field | Default | Meaning |
|-------|---------|---------|
| `enable_harness_rsi` | `false` | Run one baseline-versus-two-candidates comparison before the task |
| `harness_task_tag` | `"general"` | Exact tag used to store and reuse winning patches |
| `harness_rsi_k` | `1` | Reserved. Values above 1 still run a single round |
| `harness_call_budget` | `5` | Executor calls for one RSI task. Below 4, the task runs once on the baseline |

An enabled task does three probe executions, then one official execution of the winner, unless `--harness-call-budget` is below 4. In that case the baseline runs once and is the answer. A patch that would push the prompt or checklist past 512 bytes is discarded and does not fail the task. The official run also skips the prompt cache when the harness changes the prompt, checklist, tool list, or retries. Candidate A can hide the first failing tool when other tools remain and the remaining list is at most 16 names. Fewer errors win a comparison. Equal errors are broken by fewer failed tools. If that still ties, the harness version does not change. If the official run loses that comparison to the baseline probe, the harness rolls back to its parent, including an older version stored in `harness_history`, that patch takes one loss, and the parent is run once more when the call budget still has room. That later run is the answer returned. The kept harness stays in memory for the next task in the same process. Every tool call in a step is recorded, not only the first.

Saved patches live in `harness_patterns` inside `--db-path` and are reused only when `task_tag` matches exactly and `wins > losses`. A patch already present in the loaded harness is not appended again. The kept harness itself is stored in `harness_snapshots` for the same tag, so a new process starts from that harness. Failed tool names from the kept run are stored in `harness_failures` and feed the next proposal when skill self-improve is off. Without `--db-path`, all of this stays in the current process only.

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
