# Memory System

knot3bot includes a flexible memory system for storing conversation history and agent state.

## Architecture

```
┌──────────────────────────────────────┐
│           MemoryManager              │
│  (Routes to appropriate backend)      │
└───────────────┬──────────────────────┘
                │
    ┌───────────┴───────────┐
    ▼                       ▼
┌─────────┐           ┌───────────┐
│ InMemory │           │  SQLite   │
│ Backend  │           │  Backend  │
└─────────┘           └───────────┘
```

## Backends

### In-Memory Backend

Default backend. Fast but non-persistent.

**Characteristics:**
- All data in RAM
- Lost on restart
- No query capability
- Fastest performance

**Usage:**
```bash
# Default (in-memory)
knot3bot

# Explicit
knot3bot --db-path ""  # Empty = in-memory
```

### SQLite Backend

Persistent storage with full SQL querying.

**Characteristics:**
- Persistent across restarts
- SQL query support
- Larger memory footprint
- Disk I/O overhead

**Usage:**
```bash
knot3bot --db-path ./memory.db
```

The CLI and the HTTP server always keep an in-memory backend. With `--db-path` they also open SQLite, write each message to both, and read SQLite first. An empty `--db-path` leaves the process on memory only. `INSERT OR IGNORE` makes a second start with the same session id succeed.

## Sessions

`--session <id>` names the conversation stored in the selected backend. The TUI starts a fresh conversation with `/new`. `/new` waits if a reply is still running. The prompt does not list sessions; `GET /api/sessions` does that when the server is running.

## Memory tool

The `memory` tool edits `MEMORY.md` or `USER.md`. `target` is `memory` or `user`. `action` is `add`, `replace`, or `remove`. `add` and `replace` take `content`. `replace` and `remove` take `old_text`.

## Harness rows

With `--enable-harness-rsi` and `--db-path`, the same SQLite file also stores `harness_patterns`, `harness_snapshots`, `harness_failures`, and `harness_history`. History keeps the newest eight versions of a task tag. See [architecture.md](architecture.md).

## Context Compression

When context grows large, the agent can compress old messages:

### Compression Strategy

1. Identify tool results that can be summarized
2. Keep system prompt and recent messages
3. Replace old tool results with summaries
4. Maintain semantic meaning

### Compression Trigger

Before an LLM call, the agent estimates tokens in the current transcript. The compressor uses a context length of 128000 unless one was configured, and it compresses when the estimate reaches half of that length. It prunes old tool results, then summarizes a middle span while keeping a protected head and a token-bounded tail. Compression runs inside that loop.

## Database path

```bash
knot3bot --db-path ./knot3bot.db
```

Rows stay until something deletes them.

## Next Steps

- [Architecture Overview](architecture.md) — System architecture
- [CLI Reference](cli.md) — Memory-related CLI options
