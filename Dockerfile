# syntax=docker/dockerfile:1

# Runtime image using the locally-built static musl binary
FROM alpine:3.23

LABEL org.opencontainers.image.source=https://github.com/knot3bot/knot3bot

RUN apk add --no-cache ca-certificates curl tzdata

# Create non-root user
RUN addgroup -S knot3bot && adduser -S knot3bot -G knot3bot

COPY zig-out/bin/knot3bot /usr/local/bin/knot3bot
COPY ui/ /app/ui/

# Ensure the app directory is owned by the non-root user
RUN chown -R knot3bot:knot3bot /app

WORKDIR /app

# Create data and logs directories
RUN mkdir -p /app/data /app/logs && chown -R knot3bot:knot3bot /app/data /app/logs

VOLUME ["/app/data", "/app/logs"]

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD wget --no-verbose --tries=1 --spider http://localhost:8080/health || exit 1

USER knot3bot

ENTRYPOINT ["/usr/local/bin/knot3bot"]
CMD ["--server", "--port", "8080"]
