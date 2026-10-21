# Quick Start

Get knot3bot running in under 5 minutes.

## 1. Set Up API Key

knot3bot requires an API key from one of the supported providers:

```bash
# Option A: Set environment variable
export OPENAI_API_KEY=sk-...

# Option B: Use a provider-specific variable
export BAILIAN_API_KEY=...
```

See [Configuration](configuration.md) for all supported providers.

## 2. Run Interactive Mode

```bash
./zig-out/bin/knot3bot --provider openai
```

Interactive mode uses the libvaxis TUI. Wide terminals show a session rail, the transcript, a `>` composer, and a workbar. `/help` opens a list you move with the arrow keys. Harness comparison stays off unless you pass `--enable-harness-rsi`. The screen waits for the whole reply; it does not draw tokens one by one. You can keep typing, and Enter stores one follow-up until that reply arrives.

## 3. Try a Task

Let's do something useful:

```
> Create a file called hello.txt with "Hello, World!" in it
```

The agent will use the file operations tool to create the file.

## 4. Server Mode

Run as an HTTP API server:

```bash
./zig-out/bin/knot3bot --server --port 8080
```

Then send requests:

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "gpt-5.5",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## 5. Interactive Commands

`/help` opens `/model`, `/config`, `/tools`, `/skills`, `/new`, and `/quit`. Up and down move, Enter runs the line, Esc closes the list. `/h` and `/q` match `/help` and `/quit`. Keys, menus, and what happens during a reply are in [CLI Reference](cli.md#interactive-tui).

## Example Tasks

### Code Review

```
> Review the code in src/agent/ and suggest improvements
```

### File Operations

```
> Find all .zig files larger than 100 lines and count their total lines
```

### Web Search

```
> Search for the latest news about Zig programming language
```

### Git Operations

```
> Show me the recent commits on main branch
```

## Session Persistence

By default, sessions are in-memory. For persistence:

```bash
# Save to SQLite database
./zig-out/bin/knot3bot --db-path ./memory.db

# Continue a previous session
./zig-out/bin/knot3bot --session my-session
```

## Next Steps

- [CLI Reference](cli.md) — Complete command reference
- [HTTP API](api.md) — REST API documentation
- [Tools Reference](tools.md) — All available tools
- [Configuration](configuration.md) — Advanced configuration
