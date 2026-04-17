# syntax=docker/dockerfile:1

# Runtime image using the locally-built static musl binary
FROM alpine:3.23

LABEL org.opencontainers.image.source=https://github.com/n0x/knot3bot

RUN apk add --no-cache ca-certificates curl tzdata

COPY zig-out/bin/knot3bot /usr/local/bin/knot3bot
COPY ui/ /app/ui/

WORKDIR /app
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/knot3bot"]
CMD ["--server", "--port", "8080"]
