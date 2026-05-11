---
name: debug
description: Systematic debugging methodology. Reproduce, isolate, diagnose, and fix bugs efficiently.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Debugging, Troubleshooting, Bug Fix]
    category: development
---

# Debug

A systematic approach to finding and fixing bugs.

## When to Use
- User reports a bug, error, crash, or unexpected behavior
- Tests are failing with unclear causes
- System behaves differently than expected

## Process

1. **Reproduce**: Understand the exact steps to trigger the bug
2. **Isolate**: Narrow down to the minimal reproduction case
3. **Diagnose**: Read error messages carefully, check logs, trace code paths
4. **Hypothesize**: Form a theory about the root cause
5. **Test**: Verify the hypothesis with targeted tests or logging
6. **Fix**: Apply the minimal fix addressing the root cause
7. **Verify**: Confirm the fix works without breaking other things
8. **Prevent**: Add tests to prevent regression

## Common Patterns
- Read the full error message before acting
- Check recent changes first (git diff, git log)
- Use binary search to isolate (comment out half the code)
- Check assumptions: types, nullability, async/await, ownership
- Look at the data, not just the code
- Add targeted logging rather than guessing
