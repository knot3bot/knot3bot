# Provider System

knot3bot talks to one provider per process. The model menu and default model for that provider are the lists in [configuration.md](configuration.md).

## Transports

| Transport | Providers | Client |
|-----------|-----------|--------|
| OpenAI-compatible HTTP | openai, deepseek, kimi, kimi-plan, minimax, minimax-plan, zai, bailian, bailian-plan, volcano, volcano-plan, openrouter, tencent, tencent-plan | `src/providers/openai_compatible.zig` |
| Anthropic Messages API | anthropic | `src/providers/anthropic.zig` |

Anthropic tool calls are converted to and from the tool shape the agent uses for every other provider.

Each provider exposes `models()`, `defaultModel()`, and `name()`. `name()` is the display string (`OpenAI`, `Anthropic`, `DeepSeek`, …) and is what `/health` and `/ready` return.

## Choosing a provider

```bash
export OPENAI_API_KEY=sk-...
knot3bot --provider openai

export ANTHROPIC_API_KEY=sk-ant-...
knot3bot --provider anthropic --model claude-sonnet-4-6

export DEEPSEEK_API_KEY=...
knot3bot --provider deepseek
```

`--model` must be a name from that provider's menu. An unknown name is rejected at startup.

## Credential pool

The interactive TUI and the HTTP server collect extra keys from the environment. For the selected provider they read `NAME` and then `NAME_2` through `NAME_5`, and they stop at the first missing suffix. `OPENAI_API_KEY` plus `OPENAI_API_KEY_2` is a pool of two. `OPENAI_API_KEY` plus `OPENAI_API_KEY_3` with no `_2` is a pool of one.

The pool rotates the key used to build the HTTP client. It does not change the provider.

## Model selection

Interactive mode and the HTTP server turn on model selection when a model registry is loaded. Selection stays on the current provider's menu. A name from `provider.models()` is sent as-is. Routing runs when the configured name is on neither that menu nor the metadata registry.
