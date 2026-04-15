# Provider System

knot3bot supports multiple LLM providers through a unified interface.

## Overview

```
┌─────────────────────────────────────┐
│            Agent Core               │
└───────────────┬─────────────────────┘
                │ chat() / chatWithTools()
                ▼
┌─────────────────────────────────────┐
│          Provider Interface          │
│  (unified API for all providers)    │
└───────────────┬─────────────────────┘
                │
    ┌───────────┼───────────┐
    ▼           ▼           ▼
┌────────┐ ┌────────┐ ┌────────┐
│ OpenAI │ │Anthropic│ │ Kimi   │
└────────┘ └────────┘ └────────┘
```

## Supported Providers

| Provider | Models | Tool Support | API Style |
|----------|--------|--------------|----------|
| OpenAI | GPT-4, GPT-3.5 | Native | OpenAI |
| Anthropic | Claude 3 | Native | Anthropic |
| Kimi | moonshot-v1 | Via adapter | OpenAI-compatible |
| MiniMax | abab6-chat | Via adapter | OpenAI-compatible |
| ZAI | glm-4 | Via adapter | OpenAI-compatible |
| Bailian | qwen-plus | Via adapter | OpenAI-compatible |
| Volcano | doubao-pro | Via adapter | OpenAI-compatible |

## Provider Interface

All providers implement:

```zig
pub const Provider = interface {
    /// Send chat request
    fn chat(messages: []Message) !ChatResponse;

    /// Send chat with tools
    fn chatWithTools(messages: []Message, tools: []Tool) !ChatResponse;

    /// List available models
    fn models() []const []const u8;

    /// Get default model
    fn defaultModel() []const u8;

    /// Get provider name
    fn name() []const u8;
};
```

## OpenAI Provider

### Configuration

```bash
export OPENAI_API_KEY=sk-...
knot3bot --provider openai --model gpt-4
```

### Available Models

| Model | Context | Tool Support |
|-------|---------|--------------|
| gpt-4o | 128K | Yes |
| gpt-4-turbo | 128K | Yes |
| gpt-4 | 8K / 32K | Yes |
| gpt-3.5-turbo | 16K | Yes |

## Anthropic Provider

### Configuration

```bash
export ANTHROPIC_API_KEY=sk-ant-...
knot3bot --provider anthropic --model claude-3-5-sonnet-20241022
```

### Available Models

| Model | Context | Tool Support |
|-------|---------|--------------|
| claude-3-5-sonnet | 200K | Yes |
| claude-3-opus | 200K | Yes |
| claude-3-sonnet | 200K | Yes |
| claude-3-haiku | 200K | Yes |

### Tool Calling

Anthropic uses a different tool format. knot3bot automatically:
- Converts OpenAI-style tools to Anthropic format
- Converts Anthropic tool results back to OpenAI format
- Maintains compatibility across providers

## OpenAI-Compatible Providers

Kimi, MiniMax, ZAI, Bailian, and Volcano use the OpenAI-compatible API.

### Configuration

```bash
# Kimi
export KIMI_API_KEY=...
knot3bot --provider kimi

# Bailian (Qwen)
export BAILIAN_API_KEY=...
knot3bot --provider bailian --model qwen-plus

# Custom base URL (if needed)
# Via config file
```

## Smart Routing

The agent can automatically select the best provider/model:

### Routing Strategy

1. **Task Analysis**: Analyze request complexity
2. **Context Check**: Match to available context lengths
3. **Cost Optimization**: Prefer cheaper models for simple tasks
4. **Availability**: Fallback on failures

### Enabling Smart Routing

```bash
knot3bot --smart-routing
```

Or via config:

```json
{
  "behavior": {
    "smart_routing": true
  }
}
```

## Credential Pooling

For high-volume usage, rotate across multiple API keys:

```bash
export OPENAI_API_KEY_1=sk-...
export OPENAI_API_KEY_2=sk-...
export OPENAI_API_KEY_3=sk-...
```

The agent will distribute requests across keys automatically.

## Error Handling

### Provider Errors

| Error | Action |
|-------|--------|
| 401 Unauthorized | Check API key |
| 429 Rate Limited | Retry with backoff |
| 500 Server Error | Retry |
| Circuit Open | Fast fail |

### Fallback Chains

Configure fallback providers:

```json
{
  "providers": {
    "primary": "openai",
    "fallback": ["anthropic", "bailian"]
  }
}
```

## Custom Providers

### Adding a New Provider

1. Create provider file: `src/providers/myprovider.zig`
2. Implement `Provider` interface
3. Add to enum in `src/providers/root.zig`

```zig
pub const Provider = enum {
    openai,
    anthropic,
    kimi,
    minimax,
    zai,
    bailian,
    volcano,
    myprovider,  // Add here
};
```

4. Register in agent config

## Performance

### Latency Comparison

| Provider | Avg Latency | Notes |
|----------|-------------|-------|
| OpenAI | ~500ms | May vary by region |
| Anthropic | ~600ms | Generally consistent |
| Bailian | ~300ms | Fast in China |

### Cost Optimization

- Simple tasks → use smaller/cheaper models
- Tool use → prefer providers with native support
- Long contexts → use providers with large context

## Next Steps

- [Architecture Overview](architecture.md) — System architecture
- [Configuration](configuration.md) — Provider configuration
