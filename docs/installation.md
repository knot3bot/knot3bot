# Installation

knot3bot runs as a single binary with zero runtime dependencies.

## Requirements

- **Zig** 0.15.2 or later
- **SQLite** (optional, for persistent memory)
  - macOS: included by default
  - Linux: `apt install libsqlite3-dev` or equivalent
  - Windows: included in SQLite prebuilt binaries

## Install from Source

### 1. Clone the Repository

```bash
git clone https://github.com/your-org/knot3bot.git
cd knot3bot
```

### 2. Build

```bash
zig build
```

The binary will be at `zig-out/bin/knot3bot`.

### 3. Run

```bash
# Interactive mode
./zig-out/bin/knot3bot

# Or add to PATH
export PATH="$PWD/zig-out/bin:$PATH"
knot3bot --help
```

## Docker

### Pre-built Image

```bash
docker run -it \
  -e OPENAI_API_KEY=$OPENAI_API_KEY \
  ghcr.io/your-org/knot3bot:latest
```

### With Docker Compose

```bash
# Create .env with your API keys
cp .env.example .env
# Edit .env with your API keys

# Start
docker compose up
```

### Build Your Own Image

```bash
docker build -t knot3bot .
docker run -it knot3bot
```

## Platform-Specific Notes

### macOS

```bash
# Install Zig via Homebrew
brew install zig

# Build
zig build
```

### Linux

```bash
# Install dependencies
apt install zig sqlite3 libsqlite3-dev

# Build
zig build
```

### Windows

Download and install Zig from [ziglang.org](https://ziglang.org/download/), then:

```cmd
zig build
```

## Verify Installation

```bash
./zig-out/bin/knot3bot --help
```

You should see:

```
knot3bot - AI Agent in Zig

Usage: knot3bot [options]

Options:
  --help, -h              Show this help message
  --db-path <path>        SQLite database path (default: in-memory)
  --session <id>          Session ID (default: default)
  --model <name>          LLM model name
  --provider <name>        LLM provider: openai, anthropic, kimi, minimax, zai, bailian, volcano
  --max-iterations <n>    Max ReAct iterations (default: 10)
  --server                Run in HTTP server mode
  --port <port>           Server port (default: 8080)
```

## Next Steps

- [Quick Start Guide](quickstart.md) — Run your first agent task
- [Configuration](configuration.md) — Set up API keys and options
