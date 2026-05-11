---
name: write-tests
description: Write comprehensive test cases. Cover happy path, edge cases, error cases. Arrange-Act-Assert pattern.
version: 1.0.0
author: knot3bot
license: MIT
metadata:
  hermes:
    tags: [Testing, Quality, Coverage, TDD]
    category: development
---

# Write Tests

Create thorough, maintainable test suites.

## When to Use
- User asks to write tests or add test coverage
- New code needs testing before merge
- Bug fix needs a regression test

## Test Structure (Arrange-Act-Assert)
1. **Arrange**: Set up test data and initial state
2. **Act**: Call the function under test
3. **Assert**: Verify the expected outcome
4. **Clean up**: Free resources (use defer)

## Coverage Checklist
- Happy path: normal input produces expected output
- Edge cases: empty, null, zero, boundary values, large inputs
- Error cases: invalid input, failure conditions
- Integration points: interactions with other modules
- Use descriptive test names that explain the scenario
