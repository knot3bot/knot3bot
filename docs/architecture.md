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
│  │     Harness RSI (default off)    │   │
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

## Interactive TUI

`src/tui/vaxis_tui.zig` draws the screen. `runCliMode` in `src/main.zig` owns the event loop and the agent. A reply calls `Agent.run` on a side thread, one model request per user message, so the composer can keep taking keys. The UI thread joins that thread when the reply is done, then appends the answer. It does not subscribe to provider chunks. A 100 ms ticker refreshes the spinner and the elapsed time. Ctrl-C restores the terminal and leaves the process without joining a call that is still on the network.

The screen copies every painted string into a frame arena before `render`, because libvaxis keeps those slices until the frame is flushed. The Kitty keyboard protocol is turned off after the terminal query so an IME can deliver UTF-8. Mouse reporting is button and wheel events, which scroll the transcript.

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

### Harness RSI

`AgentConfig.enable_harness_rsi` defaults to `false`. With the switch off, `runWithSteps` keeps the previous control flow, including prompt-cache reads and writes.

With the switch on, k stays 1 even if `harness_rsi_k` is greater than 1. Each task pays for three probe executions (the baseline plus two candidates) and then one official run of the winner. If that official run is worse than the baseline probe, one more run of the parent harness replaces it. Probe executions set `bypass_prompt_cache`, so they do not read or write the prompt cache. The official run uses the cache only when the harness leaves the prompt, checklist, tool list, and retries unchanged. A harness that changes any of those skips the cache, because the cache key is the user query alone.

A candidate replaces the baseline only when pairwise comparison produces a unique winner. Fewer `error_count` wins. Equal error counts are broken by fewer failed tools. A remaining tie leaves the harness version unchanged. Probe runs use the candidate's `max_retries` and `tool_order`. An empty `tool_order` leaves every registry tool visible. When a failing tool is known and at least one other registry tool would remain, and that remainder is at most 16 names, candidate A replaces `tool_order` with the registry minus that failing tool. The winning prompt section is appended to the system prompt, and a non-empty checklist is appended under the heading `Harness checklist:`. `max_retries` retries a failed tool call only; a failure counts once, after retries are exhausted.

The same process keeps the winning harness and uses it as the next baseline. If the official run is worse than the baseline probe on that same comparison, the session rolls back to the parent harness, searching `harness_history` as well as the in-memory baseline. It runs that parent once more when the call budget still allows it, and returns that run. `--harness-call-budget` defaults to 5. A value below 4 skips the comparison and runs the baseline once. A patch that exceeds 512 bytes is discarded instead of failing the task. A saved patch is not applied again when its text is already in the baseline. With `harness_db_path` set, the kept harness is stored in `harness_snapshots`, older versions stay in `harness_history` (at most 8), and failed tool names from every tool call in the kept run are stored in `harness_failures`. Cross-task patch memory is the `harness_patterns` table. `lookup` matches `task_tag` exactly, returns at most two rows, and only rows where `wins > losses`. Only the first of those rows can replace a propose slot. One request rolls back at most one parent hop; older bytes in `harness_history` are available on a later task. Propose and the judge stay deterministic: there is no model call that writes the patch or picks the winner, and `harness_rsi_k` above 1 still runs a single round.

Tools with no external implementation (`homeassistant`, `image_generation`, `send_message`, `tts`, `transcription`, `vision`, `screen_capture`) are not in the default registry. Calling `execute` on them returns `success = false`.

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
| Workspace | shell, read_file, write_file, list_directory, grep, glob, diff |
| Web | http_request, web_fetch, web_search, web_extract, browser |
| Git and process | git, cron, spawn |
| Agent control | todo, interrupt, clarify, approval, task_planner, delegate, delegate_result |
| Memory and skills | memory, session_search, skills_list, skill_view, skill_manager, skill_run, skill_self_improve |
| Other | calculator, checkpoint, credential_files, env_passthrough, url_safety, mcp, mcp_list_servers, code_execution |

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
