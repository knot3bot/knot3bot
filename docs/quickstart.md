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

You'll see:

```
knot3bot v0.0.1

Session: default | Memory: in-memory | Provider: openai | Model: gpt-4
Commands: exit/quit, clear, sessions

> _
```

Type your question and press Enter:

```
> Hello, what can you do?

[Agent running...]

Final Answer:
Hello! I'm knot3bot, an AI coding agent built in Zig. I can help you with:

• Writing and editing code
• Reading and analyzing files
• Running shell commands
• Git operations
• Web searches and fetches
• And much more!

Just describe what you need, and I'll help you accomplish it.

Iterations: 1 | Tool calls: 0 | API calls: 1
```

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
    "model": "gpt-4",
    "messages": [{"role": "user", "content": "Hello!"}]
  }'
```

## 5. Interactive Commands

In CLI mode:

| Command | Description |
|--------|-------------|
| `exit`, `quit` | Exit the program |
| `clear` | Clear current session |
| `sessions` | List all sessions |

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
