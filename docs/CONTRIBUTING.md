# Contributing to knot3bot

Thank you for your interest in contributing to knot3bot!

## Getting Started

1. **Fork** the repository
2. **Clone** your fork:
   ```bash
   git clone https://github.com/your-username/knot3bot.git
   cd knot3bot
   ```
3. **Build** to ensure everything compiles:
   ```bash
   zig build
   ```
4. **Test** that tests pass:
   ```bash
   zig build test
   ```

## Development Workflow

### 1. Create a Branch

```bash
git checkout -b feature/my-feature
# or
git checkout -b fix/some-bug
```

### 2. Make Changes

- Follow the [Code Style](#code-style)
- Add tests for new functionality
- Update documentation

### 3. Test

```bash
zig build test
zig fmt --check src/  # Check formatting
```

### 4. Commit

```bash
git add .
git commit -m "feat: add new feature"
```

Follow [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation
- `refactor:` Code refactoring
- `test:` Adding tests
- `chore:` Maintenance

### 5. Push and PR

```bash
git push origin feature/my-feature
```

Then open a Pull Request on GitHub.

## Code Style

### Formatting

knot3bot uses Zig's built-in formatter:

```bash
zig fmt src/
```

### Naming Conventions

| Type | Convention | Example |
|------|------------|---------|
| Functions | snake_case | `create_agent()` |
| Variables | snake_case | `max_iterations` |
| Types | PascalCase | `AgentConfig` |
| Enums | PascalCase | `Provider` |
| Constants | SCREAMING_SNAKE | `MAX_TIMEOUT` |

### Error Handling

- Use `try` for errors that should propagate
- Use `catch` for expected errors with fallbacks
- Never use `catch unreachable` for normal errors

```zig
// Good
try someFunction();
const result = something() catch defaultValue;

// Bad
try someFunction();
catch unreachable;  // Hides real errors
```

### Documentation

Document public APIs with doc comments:

```zig
/// Creates a new agent with the given configuration.
/// Returns error on invalid config.
pub fn createAgent(config: AgentConfig) !*Agent {
    // ...
}
```

## Testing

### Running Tests

```bash
# All tests
zig build test

# Specific test
zig test src/some_module.zig --test-filter "test_name"
```

### Writing Tests

```zig
test "my feature" {
    const result = doSomething();
    try std.testing.expect(result == expected);
}
```

## Areas for Contribution

### High Priority

- [ ] More LLM providers
- [ ] Additional tools
- [ ] Performance improvements
- [ ] Documentation translations

### Medium Priority

- [ ] Windows support improvements
- [ ] WebSocket streaming
- [ ] Session export/import

### Low Priority

- [ ] Plugin system
- [ ] Language bindings
- [ ] IDE integrations

## Reporting Issues

### Bug Reports

Include:
- Zig version (`zig version`)
- Platform (macOS, Linux, Windows)
- Steps to reproduce
- Expected vs actual behavior

### Feature Requests

Describe:
- Use case
- Expected behavior
- Why this would be valuable

## Code of Conduct

- Be respectful and inclusive
- Give constructive feedback
- Help others learn
- Focus on the work, not the person

## License

By contributing, you agree that your contributions will be licensed under the MIT License.
