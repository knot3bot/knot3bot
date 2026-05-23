---
name: prompt-engineering
description: Craft effective prompts for LLMs - chain-of-thought, few-shot, system prompts, and tool use guidance
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Prompt Engineering, LLM, AI, System Design]
    category: ai
---

# Prompt Engineering

Design effective prompts for LLM interactions.

## When to Use
- Writing system prompts for AI agents
- Optimizing few-shot examples
- Debugging LLM output quality

## Techniques
- Chain-of-thought: ask model to reason step by step
- Few-shot: provide 2-3 examples of desired output format
- System prompt: set clear role, constraints, and output format
- Tool use guidance: describe when and how to use each tool
- Output format: specify JSON/Markdown/table format explicitly
- Iterative refinement: test, observe, adjust

## Common Pitfalls
- Overly long prompts waste tokens
- Ambiguous instructions lead to inconsistent output
- Missing output format spec causes parsing errors
- Too many tools listed in system prompt confuses some models
