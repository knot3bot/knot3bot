---
name: refactor
description: Safe code refactoring. Improve structure without changing behavior. Apply one refactoring at a time.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Refactoring, Code Quality, Clean Code]
    category: development
---

# Refactor

Improve code structure without changing external behavior.

## When to Use
- User asks to refactor, clean up, improve, or restructure code
- Code works but is hard to maintain, test, or extend
- Before adding significant new features

## Process
1. Understand current behavior (read tests, check callers)
2. Identify the specific problem: duplication, coupling, complexity
3. Choose the right refactoring: extract function, rename, simplify, invert dependency
4. Apply one refactoring at a time, minimal changes
5. Verify tests pass after each step

## Safety Rules
- Never change behavior and structure simultaneously
- Keep refactoring commits separate from feature commits
- Write characterization tests before refactoring untested code
- Use grep to find all references before renaming
- Run the test suite after each change
