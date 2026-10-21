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
    "model": "gpt-5.5"
  },
  "memory": {
    "backend": "sqlite",
    "db_path": "/path/to/memory.db"
  },
  "server": {
    "port": 8080,
    "host": "127.0.0.1"
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

`src/config.zig` parses this file. `loadDefault` checks `KNOT3BOT_CONFIG`, then `~/.knot3bot/config.json`, then `./knot3bot.json`. The CLI and the HTTP server read the flags and environment variables below. The `mcp` tool reads those same paths for an `mcp_servers` array.

## CLI Flags

```bash
knot3bot [options]

Options:
  --help, -h              Show this help message
  --db-path <path>        SQLite database path (default: in-memory)
  --session <id>          Session ID (default: default)
  --model <name>          LLM model name
  --provider <name>       LLM provider: openai, deepseek, kimi, minimax, zai, bailian, volcano, openrouter, tencent (+ -plan variants)
  --max-iterations <n>    Max ReAct iterations (default: 10)
  --server                Run in HTTP server mode
  --acp                   Serve ACP over stdio
  --port <port>           Server port (default: 8080)
  --config, configure     Run the configuration wizard
  --enable-skill-self-improve  Enable skill self-improvement (default: off)
  --enable-harness-rsi    Enable harness RSI (default: off)
  --harness-tag <tag>     Harness task tag (default: general)
  --harness-call-budget <n>  Max harness executor calls (default: 5)
```

## Provider Configuration

`--provider` selects one of the providers below. The default model is used when `--model` is omitted. The interactive `/model` menu lists every name in the third column.

| Provider | Environment variable | Default model | Menu |
|----------|----------------------|---------------|------|
| `openai` | `OPENAI_API_KEY` | `gpt-5.5` | `gpt-5.5`, `gpt-5.5-mini`, `gpt-5.1`, `o5-mini`, `o4-mini`, `gpt-4o` |
| `anthropic` | `ANTHROPIC_API_KEY` | `claude-sonnet-4-6` | `claude-opus-4-7`, `claude-sonnet-4-6`, `claude-haiku-4-5`, `claude-3-5-sonnet-20241022` |
| `deepseek` | `DEEPSEEK_API_KEY` | `deepseek-v4-pro` | `deepseek-v4-pro`, `deepseek-v4-flash`, `deepseek-chat`, `deepseek-reasoner`, `deepseek-coder` |
| `kimi`, `kimi-plan` | `KIMI_API_KEY` | `kimi-k2.5` | `kimi-k2.5`, `kimi-k2-thinking`, `kimi-k2-turbo-preview`, `moonshot-v1-auto`, `moonshot-v1-128k` |
| `minimax`, `minimax-plan` | `MINIMAX_API_KEY` | `MiniMax-M2.7` | `MiniMax-M2.7`, `MiniMax-M2.5`, `MiniMax-M2.1`, `MiniMax-M2`, `abab7-chat` |
| `zai` | `ZAI_API_KEY` | `glm-4.7` | `glm-4.7`, `glm-4.7-flash`, `glm-4.6`, `glm-4-plus`, `glm-4-flash-x` |
| `bailian`, `bailian-plan` | `BAILIAN_API_KEY` | `qwen3.6-plus` | `qwen3.6-plus`, `qwen3.6-flash`, `qwen3.6-coder-plus`, `qwen3-max-plus`, `qwen-vl-max` |
| `volcano` | `VOLCANO_API_KEY` | `doubao-seed-1-8-251228` | `doubao-seed-1-8-251228`, `doubao-pro-32k`, `doubao-pro-128k`, `doubao-lite-32k`, `doubao-seed-1-6-250615` |
| `volcano-plan` | `VOLCANO_API_KEY` | `ark-code-latest` | `ark-code-latest`, `doubao-seed-code`, `glm-4.7`, `kimi-k2-thinking`, `doubao-seed-code-preview-251028` |
| `openrouter` | `OPENROUTER_API_KEY` | `openai/gpt-4o` | `openai/gpt-5.1`, `anthropic/claude-opus-4.7`, `anthropic/claude-sonnet-4.6`, `google/gemini-2.5-pro`, `meta-llama/llama-4-maverick`, `deepseek/deepseek-v3-0324` |
| `tencent`, `tencent-plan` | `TENCENT_API_KEY` | `hunyuan-lite` | `hunyuan-turbo-latest`, `hunyuan-t1-latest`, `hunyuan-standard`, `hunyuan-lite`, `hunyuan-vision` |

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

Saved patches live in `harness_patterns` inside `--db-path` and are reused only when `task_tag` matches exactly and `wins > losses`. Lookup returns at most two rows; only the first prior can replace a candidate. A patch already present in the loaded harness is not appended again. The kept harness itself is stored in `harness_snapshots` for the same tag, and `harness_history` keeps the newest 8 versions so a later rollback can see an older parent. A new process starts from the latest snapshot. Failed tool names from every tool call in the kept run are stored in `harness_failures` and feed the next proposal when skill self-improve is off. Without `--db-path`, all of this stays in the current process only. One request rolls back at most one parent hop.

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
