# CLI Reference

Complete reference for the knot3bot command-line interface.

## Synopsis

```bash
knot3bot [options]
knot3bot --server [options]
```

## Global Options

| Flag | Description | Default |
|------|-------------|---------|
| `--help`, `-h` | Show help message | - |
| `--config`, `configure` | Run the configuration wizard | - |
| `--db-path <path>` | SQLite database path. Also stores harness snapshots when RSI is on | in-memory |
| `--session <id>` | Session identifier | `default` |
| `--model <name>` | LLM model name | provider default |
| `--provider <name>` | `openai`, `deepseek`, `kimi`, `minimax`, `zai`, `bailian`, `volcano`, `openrouter`, `tencent`, plus `-plan` variants | `openai` |
| `--max-iterations <n>` | Max ReAct iterations | `10` |
| `--server` | Run HTTP server mode | off |
| `--acp` | Serve ACP over stdio | off |
| `--port <port>` | Server port | `8080` |
| `--enable-skill-self-improve` | Record tool outcomes for skill suggestions | off |
| `--enable-harness-rsi` | Compare one harness patch set before answering | off |
| `--harness-tag <tag>` | Task tag for harness memory | `general` |
| `--harness-call-budget <n>` | Max harness executor calls. Below 4, the baseline runs once | `5` |

## Interactive Mode Commands

When running in interactive mode, these commands are available at the prompt:

| Command | Description |
|---------|-------------|
| `/help`, `/h` | Show commands |
| `/quit`, `/q` | Exit |
| `/new` | Clear the transcript and start the stored session over |
| `/config` | Show the current configuration |
| `/model` | Open the model menu. Enter switches the live client |
| `/model <name>` | Switch to a name on this provider's menu |
| `/tools` | List registered tools |
| `/skills` | List skill directories under the workspace `skills/` folder |

The configuration wizard is `--config`, not a slash command. Harness flags apply to interactive mode, `--server`, and `--acp`. With RSI on and `--db-path` set, the same database holds `harness_patterns`, `harness_snapshots`, `harness_history` (newest 8 versions per tag), and `harness_failures`.

## Examples

### Basic Usage

```bash
# Interactive mode with default provider (OpenAI)
knot3bot

# Specify provider
knot3bot --provider anthropic

# Use specific model
knot3bot --model gpt-5.5

# Limit iterations
knot3bot --max-iterations 5
```

### Session Management

```bash
# Start new session
knot3bot --session project-x

# Continue previous session
knot3bot --session project-x

# List available sessions
knot3bot --session sessions

# Use SQLite for persistence
knot3bot --db-path ./memory.db --session project-x
```

### Server Mode

```bash
# Basic server
knot3bot --server

# Custom port
knot3bot --server --port 3000

# With specific model
knot3bot --server --provider bailian --model qwen3.6-plus

# One harness comparison round, persisted with the session database
knot3bot --enable-harness-rsi --harness-tag code --db-path ./memory.db

# ACP over stdio
knot3bot --acp
```

### Environment Variables

```bash
# Set API key
OPENAI_API_KEY=sk-... knot3bot

# Or export first
export OPENAI_API_KEY=sk-...
knot3bot
```

## Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Success |
| `1` | Error (invalid arguments, API error, etc.) |

## Signal Handling

knot3bot handles `SIGINT` (Ctrl+C) and `SIGTERM` gracefully, cleaning up resources before exit.

## Next Steps

- [Quick Start](quickstart.md) — Getting started tutorial
- [Configuration](configuration.md) — Configuration options
- [HTTP API](api.md) — REST API documentation
