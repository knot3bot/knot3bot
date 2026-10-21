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

## Interactive TUI

`knot3bot` with no `--server` or `--acp` opens the libvaxis screen. A terminal at least 76 columns wide has four zones: a session rail, the transcript, the composer, and a one-line workbar. Narrower terminals drop the rail and keep the other three. The rail shows the provider, model, session id, registered tool count, and the last prompt and completion token counts.

The composer prompt is `> `. Typing `/` on an empty composer enters command mode and shows `/`; the slash is not stored until Enter sends it. Bracketed paste inserts into the composer. IME commits, including Han, are inserted as UTF-8. The Kitty keyboard protocol stays off so macOS can deliver those commits.

### Slash commands

| Command | Description |
|---------|-------------|
| `/help`, `/h` | Open the command list. Up and down move, Enter runs the highlighted command, Esc closes it |
| `/quit`, `/q` | Exit and restore the terminal |
| `/new` | Clear the transcript and start the stored session over |
| `/config` | Show provider, model, session, tool count, and token counts. Esc closes the panel |
| `/model` | Open this provider's model menu. Enter applies the highlighted name |
| `/model <name>` | Switch to a name on this provider's menu |
| `/tools` | Open the registered-tool menu. The title shows the current position, for example `1/37` |
| `/skills` | Open skill directory names from the workspace `skills/` folder |

`/model`, `/tools`, and `/skills` share one menu: Up and Down move one row, Page Up and Page Down move eight, Home and End jump to the ends, Esc closes. Enter on `/tools` or `/skills` closes the menu without running a tool. The configuration wizard is `--config`, not a slash command.

`/new`, `/model <name>`, and choosing a model from the menu wait until the current reply finishes. The transcript then says `Wait for the reply to finish.`

### Composer and transcript

| Key | Action |
|-----|--------|
| Enter | Send the composer text |
| Up, Down | Recall earlier composer text from this process |
| Left, Right, Home, End | Move the cursor. Ctrl-A and Ctrl-E match Home and End |
| Ctrl-Left, Ctrl-Right | Move by word |
| Backspace, Delete | Delete the previous or next character |
| Ctrl-U, Ctrl-K, Ctrl-W | Delete to the start, to the end, or the previous word |
| Page Up, Page Down | Scroll the transcript by 10 lines |
| Mouse wheel | Scroll the transcript by 3 lines when the pointer is above the composer |
| Esc | Close an overlay, or leave command mode |
| Ctrl-C, Ctrl-Q | Quit |

History is whatever was sent in this process. There is no fixed length.

### While a reply is running

Each message is one model call on a background thread. The transcript does not paint tokens as they arrive. A spinner and the elapsed seconds stay on screen until the full answer, or an error name, replaces them. The composer stays editable.

Enter during a reply stores one follow-up. A second Enter replaces that stored text. The follow-up is sent when the current reply lands. Ctrl-C and Ctrl-Q restore the terminal and exit without waiting for the model call.

Without an API key, the user line is kept and the transcript adds `No API key configured.`

Harness flags apply to interactive mode, `--server`, and `--acp`. With RSI on and `--db-path` set, the same database holds `harness_patterns`, `harness_snapshots`, `harness_history` (newest 8 versions per tag), and `harness_failures`.

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

In the TUI, Ctrl-C and Ctrl-Q are keys. They restore the terminal and exit immediately, including while a model call is still running. `SIGTERM` sets a shutdown flag that the loop reads after the next event.

## Next Steps

- [Quick Start](quickstart.md) — Getting started tutorial
- [Configuration](configuration.md) — Configuration options
- [HTTP API](api.md) — REST API documentation
