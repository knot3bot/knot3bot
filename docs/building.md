# Building from Source

Instructions for building knot3bot on different platforms.

## Prerequisites

- **Zig** 0.15.2 or later
- **Git**
- **C compiler** (for SQLite)

## Quick Build

```bash
git clone https://github.com/your-org/knot3bot.git
cd knot3bot
zig build
```

The binary will be at `zig-out/bin/knot3bot`.

## Build Options

### Optimization Levels

```bash
# Debug (fastest compile, slowest runtime)
zig build

# ReleaseSafe (runtime safety, good performance)
zig build -Doptimize=ReleaseSafe

# ReleaseFast (no runtime safety, fastest runtime)
zig build -Doptimize=ReleaseFast

# ReleaseSmall (smallest binary, good performance)
zig build -Doptimize=ReleaseSmall
```

### SQLite Support

```bash
# With SQLite (default)
zig build

# Without SQLite
zig build -Denable-sqlite=false
```

### Cross-Compilation

```bash
# Linux x86_64 musl (static linking)
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# Linux ARM64
zig build -Dtarget=aarch64-linux-gnu -Doptimize=ReleaseSafe

# macOS Intel
zig build -Dtarget=x86_64-macos-gnu -Doptimize=ReleaseSafe

# macOS Apple Silicon
zig build -Dtarget=aarch64-macos-gnu -Doptimize=ReleaseSafe

# Windows
zig build -Dtarget=x86_64-windows-gnu -Doptimize=ReleaseSafe
```

## Platform-Specific

### macOS

```bash
# Install Zig
brew install zig

# Build
zig build
```

### Linux (Ubuntu/Debian)

```bash
# Install Zig
apt install zig

# Or download from ziglang.org
wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
tar xf zig-linux-x86_64-0.15.2.tar.xz
export PATH="$PWD/zig-linux-x86_64-0.15.2:$PATH"

# Install SQLite development files
apt install libsqlite3-dev

# Build
zig build
```

### Linux (Alpine)

```bash
apk add zig sqlite-dev
zig build
```

### Windows

1. Download Zig from [ziglang.org](https://ziglang.org/download/)
2. Add to PATH
3. Install SQLite (or use prebuilt binaries)
4. Build:

```cmd
zig build
```

## Docker Build

### Multi-stage Build

```bash
docker build -t knot3bot .
```

### Build for Different Targets

```bash
# Build inside Docker for Linux
docker run --rm -v $(pwd):/app -w /app ziglang/zig:0.15.2 zig build
```

### musl Static Build

For fully static binaries:

```dockerfile
FROM alpine:3.19 AS builder
RUN apk add zig sqlite-dev
WORKDIR /app
COPY . .
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

FROM scratch
COPY --from=builder /app/zig-out/bin/knot3bot /knot3bot
ENTRYPOINT ["/knot3bot"]
```

## Build Artifacts

| File | Description |
|------|-------------|
| `zig-out/bin/knot3bot` | Main binary |
| `zig-out/lib/` | Static libraries (if any) |
| `zig-cache/` | Build cache |

## Build Verification

```bash
# Run tests
zig build test

# Check binary size
ls -lh zig-out/bin/knot3bot

# Run help
./zig-out/bin/knot3bot --help
```

## Troubleshooting

### "sqlite3 not found"

```bash
# Ubuntu/Debian
apt install libsqlite3-dev

# macOS (usually included)
# If not: brew install sqlite

# Alpine
apk add sqlite-dev
```

### "Invalidzig version"

Check Zig version:

```bash
zig version
```

Requires 0.15.2 or later.

### Build Errors

Clean and rebuild:

```bash
rm -rf zig-cache zig-out
zig build
```

## Continuous Integration

See `.github/workflows/ci.yml` for CI configuration.

```yaml
- name: Build
  run: zig build

- name: Test
  run: zig build test

- name: Release Build
  run: zig build -Doptimize=ReleaseSmall -Dtarget=x86_64-linux-musl
```

## Performance Tuning

### Binary Size

For smallest binary:

```bash
zig build -Doptimize=ReleaseSmall
strip zig-out/bin/knot3bot
```

### Runtime Performance

For fastest runtime:

```bash
zig build -Doptimize=ReleaseFast
```

### Debugging

For debugging:

```bash
zig build -Doptimize=Debug
```

## Next Steps

- [Installation](installation.md) — Installation guide
- [Quick Start](quickstart.md) — Get started
- [Configuration](configuration.md) — Configuration options
