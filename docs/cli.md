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
| `--version` | Show version | - |
| `--db-path <path>` | SQLite database path | in-memory |
| `--session <id>` | Session identifier | `default` |
| `--model <name>` | LLM model name | provider default |
| `--provider <name>` | LLM provider | `openai` |
| `--max-iterations <n>` | Max ReAct iterations | `10` |
| `--server` | Run HTTP server mode | false |
| `--port <port>` | Server port | `8080` |

## Interactive Mode Commands

When running in interactive mode, these commands are available at the prompt:

| Command | Description |
|---------|-------------|
| `exit`, `quit` | Exit the program |
| `clear` | Clear current session |
| `sessions` | List all sessions |

## Examples

### Basic Usage

```bash
# Interactive mode with default provider (OpenAI)
knot3bot

# Specify provider
knot3bot --provider anthropic

# Use specific model
knot3bot --model gpt-4-turbo

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
knot3bot --server --provider bailian --model qwen-plus
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
