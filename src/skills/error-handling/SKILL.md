---
name: error-handling
description: Systematic error handling patterns - Result types, error propagation, logging, and user-facing messages
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Error Handling, Result, Logging, Reliability, Debug]
    category: development
---

# Error Handling

Robust error handling for production systems.

## When to Use
- Implementing error handling in new code
- Reviewing error propagation chains
- Adding logging to error paths

## Patterns
- Use typed errors, not string errors
- Propagate errors with context (wrap, not discard)
- Log errors at the boundary, not deep in the stack
- Return user-friendly messages for known errors
- Never expose internal details in error responses
- Use errdefer for cleanup on error paths
- Circuit break for external dependency failures
- Retry with exponential backoff for transient errors
