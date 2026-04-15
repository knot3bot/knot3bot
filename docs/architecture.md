# Architecture Overview

This document describes the internal architecture of knot3bot.

## System Overview

knot3bot is built in layers:

```
┌─────────────────────────────────────────┐
│              CLI / HTTP Server          │  Interface Layer
├─────────────────────────────────────────┤
│                 Agent                   │  Core Layer
│  ┌─────────────────────────────────┐   │
│  │     ReAct Loop                   │   │
│  │     Context Compression          │   │
│  │     Trajectory Recording         │   │
│  └─────────────────────────────────┘   │
├─────────────────────────────────────────┤
│              Tool Registry              │  Tool Layer
├─────────────────────────────────────────┤
│            LLM Providers                │  Provider Layer
├─────────────────────────────────────────┤
│              Memory System              │  Storage Layer
└─────────────────────────────────────────┘
```

## Agent Core

### ReAct Loop

The ReAct (Reasoning + Acting) loop is the heart of the agent:

```
User Input → Think → Plan → Act → Observe → ...
                     ↑__________________|
```

1. **Thought**: Analyze the request and plan approach
2. **Action**: Select and call a tool
3. **Observation**: Review the tool's result
4. Repeat until task is complete or max iterations reached

### Context Compression

When conversation history exceeds token budget:

1. **Measure**: Count tokens in context
2. **Identify**: Find compressible tool results
3. **Summarize**: Use LLM to create summary
4. **Replace**: Swap full results with summary

### Trajectory Recording

Every agent run is logged to JSONL for:
- Debugging and auditing
- Performance analysis
- Training data for RL (future)

## Tool System

### Tool Registry

Tools are registered at compile-time using Zig's `comptime`:

```zig
pub fn createDefaultRegistry(allocator: std.mem.Allocator) !*ToolRegistry {
    var registry = try ToolRegistry.init(allocator);

    try registry.register(read_file);
    try registry.register(write_file);
    try registry.register(shell);
    // ...

    return registry;
}
```

### Tool Execution

When a tool is called:

1. Parse tool name and arguments from LLM response
2. Validate arguments against tool schema
3. Execute tool with timeout
4. Return result to LLM for next iteration

### Tool Categories

| Category | Examples |
|----------|----------|
| File Operations | read_file, write_file, edit_file, search_files |
| Shell | shell, process_list, process_kill |
| Git | git_status, git_log, git_diff, git_branch |
| Web | web_search, web_fetch |
| Code | code_execution, code_review |
| System | cron_list, cron_add, cron_remove |
| Memory | memory_search, memory_save, memory_recall |
| MCP | mcp_list, mcp_call |
| Utility | browser, approve, interrupt, clarify |

## Provider System

### Provider Interface

All LLM providers implement a common interface:

```zig
pub const Provider = enum {
    pub fn chat(self, messages: []Message) !ChatResponse
    pub fn chatWithTools(self, messages: []Message, tools: []Tool) !ChatResponse
    pub fn models(self) []const []const u8
    pub fn defaultModel(self) []const u8
};
```

### Supported Providers

| Provider | API Style | Tool Support |
|----------|-----------|--------------|
| OpenAI | OpenAI API | Native |
| Anthropic | Anthropic API | Native (converted) |
| Kimi | OpenAI-compatible | Via adapter |
| MiniMax | OpenAI-compatible | Via adapter |
| ZAI | OpenAI-compatible | Via adapter |
| Bailian | OpenAI-compatible | Via adapter |
| Volcano | OpenAI-compatible | Via adapter |

### Smart Routing

The agent can automatically select the best provider/model based on:
- Task complexity
- Available context length
- Cost optimization
- Provider availability

## Memory System

### Backend Architecture

```
MemoryManager
├── InMemoryBackend (default)
│   └── Fast, non-persistent
└── SqliteBackend (optional)
    └── Persistent, queryable
```

### Session Management

Each session has:
- **ID**: Unique identifier
- **Messages**: Conversation history
- **Metadata**: Created, last accessed
- **TTL**: Optional expiration

### Persistence

```bash
# Use SQLite backend
knot3bot --db-path ./memory.db
```

## HTTP Server

### Endpoint Routing

```
/health          → Health check
/ready           → Readiness check (includes DB)
/v1/chat/completions → OpenAI-compatible
/v1/responses    → Extended responses
/v1/models       → Model list
/metrics         → Prometheus metrics
```

### Production Features

- **Rate Limiting**: Token bucket algorithm
- **Circuit Breaker**: Fast fail on provider errors
- **Request Validation**: JSON schema validation
- **Prometheus Metrics**: Full observability

## Data Flow

### Interactive Mode

```
stdin → parseInput → Agent.run() → ReAct Loop → Tool Registry → response → stdout
                              ↓
                       Memory Manager
                              ↓
                        SQLite/InMemory
```

### HTTP Mode

```
HTTP Request → Router → Auth → Agent → response → HTTP Response
                     ↓
              Memory Manager
```

## Performance Considerations

### Memory Management

- **Arena Allocator**: Per-request allocations, freed after request
- **General Purpose Allocator**: Long-lived state
- **No garbage collection**: Zig's manual memory management

### Concurrency

- **Thread Pool**: For blocking operations
- **Static Dispatch**: No virtual function overhead
- **No Async/Await**: Keep it simple, use threads

### Binary Size

Target: **< 2MB** stripped binary

Strategies:
- `-Os` / `-ReleaseSmall` optimization
- No unnecessary dependencies
- Static linking (musl on Linux)

## Extension Points

### Adding a New Tool

1. Create tool function in `src/tools/`
2. Add to tool spec in `src/tools/root.zig`
3. Register in `createDefaultRegistry()`

### Adding a New Provider

1. Create provider in `src/providers/`
2. Implement `Provider` interface
3. Add to `Provider` enum
4. Update CLI and config

### Adding a New Backend

1. Implement `MemoryBackend` interface
2. Register in `MemoryManager`
3. Add CLI option

## Next Steps

- [Memory System](memory.md) — Detailed memory architecture
- [Provider System](providers.md) — Provider implementation details
