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

### Multi-Backend

Can use multiple backends simultaneously for caching:

```bash
# In-memory cache + SQLite persistence
# (implemented via MemoryManager)
```

## Session Management

### Sessions

Each conversation is a "session":

```bash
# New session
knot3bot --session project-x

# Continue session
knot3bot --session project-x

# List sessions
knot3bot --session sessions
```

### Session Structure

```json
{
  "id": "project-x",
  "created_at": 1704067200,
  "updated_at": 1704070800,
  "messages": [
    {"role": "user", "content": "Hello"},
    {"role": "assistant", "content": "Hi!"}
  ]
}
```

## API

### CLI Commands

```
> sessions
Sessions: 3
  - default
  - project-x
  - debug-session

> clear
Session cleared.
```

### Tool Interface

Agents can use memory tools:

```
memory_save(key="important", value="User prefers dark mode")
memory_recall(key="important")
memory_search(query="dark mode")
```

## Context Compression

When context grows large, the agent can compress old messages:

### Compression Strategy

1. Identify tool results that can be summarized
2. Keep system prompt and recent messages
3. Replace old tool results with summaries
4. Maintain semantic meaning

### Compression Trigger

Compression is triggered when:
- Token count exceeds 80% of model limit
- Agent detects redundant information
- Manual trigger via `compress` command

## Performance

### Benchmarks

| Backend | Read | Write | Query |
|---------|------|-------|-------|
| In-Memory | < 1ms | < 1ms | < 1ms |
| SQLite | < 5ms | < 10ms | < 20ms |

### Memory Usage

- In-Memory: ~1KB per message
- SQLite: ~2KB per message (on-disk)

## Configuration

### Database Location

```bash
# Current directory
knot3bot --db-path ./knot3bot.db

# Home directory
knot3bot --db-path ~/.knot3bot/memory.db

# Custom path
knot3bot --db-path /var/lib/knot3bot/memory.db
```

### Automatic Cleanup

Old sessions can be auto-cleaned:

```json
{
  "memory": {
    "backend": "sqlite",
    "db_path": "./memory.db",
    "ttl_days": 30,
    "max_sessions": 100
  }
}
```

## Next Steps

- [Architecture Overview](architecture.md) — System architecture
- [CLI Reference](cli.md) — Memory-related CLI options
