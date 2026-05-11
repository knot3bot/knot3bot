---
name: code-review
description: Review code for bugs, security issues, performance problems, and best practices. Provide specific, actionable suggestions.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Code Review, Security, Quality, Best Practices]
    category: development
---

# Code Review

Systematic code review covering security, correctness, performance, and maintainability.

## When to Use
- User asks for code review, audit, or security check
- Before committing or merging code changes
- Evaluating third-party code or dependencies

## Review Checklist

### Security
- Injection vectors (SQL, shell, HTML, path traversal)
- Authentication and authorization bypass risks
- Hardcoded secrets, keys, tokens, or credentials
- Unsafe deserialization or dynamic code execution

### Correctness
- Logic errors and off-by-one mistakes
- Edge cases (null, empty, boundary, overflow)
- Error propagation (are errors handled or silently ignored?)
- Race conditions and deadlocks

### Performance
- Unnecessary allocations in hot paths
- O(n^2) or worse algorithmic complexity
- Blocking I/O on critical paths
- Missing caching opportunities

### Maintainability
- Clear, descriptive naming
- Single responsibility principle
- Adequate error messages for debugging
- Missing tests for critical paths

## Output Format
- **Summary**: 1-2 sentence overall assessment
- **Critical**: Issues that must be fixed immediately
- **Important**: Issues that should be fixed
- **Suggestions**: Nice-to-have improvements
