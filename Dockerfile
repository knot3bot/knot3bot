# syntax=docker/dockerfile:1

# ── Stage 1: Build ────────────────────────────────────────────
FROM alpine:3.23 AS builder

RUN apk add --no-cache zig musl-dev sqlite-dev

WORKDIR /app
COPY build.zig build.zig.zon ./
COPY src/ src/

# Build natively for linux with musl
RUN zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe

# ── Stage 2: Runtime ─────────────────────────────────────────
FROM alpine:3.23 AS release

LABEL org.opencontainers.image.source=https://github.com/n0x/knot3bot

RUN apk add --no-cache ca-certificates curl tzdata sqlite-libs

COPY --from=builder /app/zig-out/bin/knot3bot /usr/local/bin/knot3bot

# Test stage
FROM release AS test
WORKDIR /app
COPY --from=builder /app/zig-out/bin/knot3bot /usr/local/bin/knot3bot
ENTRYPOINT ["zig", "build", "test"]
CMD []