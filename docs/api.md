# HTTP API

knot3bot can run as an HTTP server with an OpenAI-compatible REST API.

## Starting the Server

```bash
knot3bot --server --port 8080
```

The server will start on `http://localhost:8080`.

## Endpoints

### Health Check

```
GET /health
```

Returns server status:

```json
{
  "status": "ok",
  "service": "knot3bot",
  "version": "0.1.0",
  "uptime_seconds": 3600,
  "provider": "openai",
  "model": "gpt-4",
  "tools": 30,
  "request_id": "abc123"
}
```

### Readiness Check

```
GET /ready
```

Returns deep health including database connectivity:

```json
{
  "ready": true,
  "provider": "openai",
  "database": "ok"
}
```

### Chat Completions (OpenAI Compatible)

```
POST /v1/chat/completions
```

Compatible with OpenAI API:

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "gpt-4",
    "messages": [
      {"role": "system", "content": "You are a helpful assistant."},
      {"role": "user", "content": "Hello!"}
    ],
    "max_tokens": 1000
  }'
```

Response:

```json
{
  "id": "chatcmpl-123",
  "object": "chat.completion",
  "created": 1704067200,
  "model": "gpt-4",
  "choices": [{
    "index": 0,
    "message": {
      "role": "assistant",
      "content": "Hello! How can I help you today?"
    },
    "finish_reason": "stop"
  }],
  "usage": {
    "prompt_tokens": 20,
    "completion_tokens": 15,
    "total_tokens": 35
  }
}
```

### Responses API

```
POST /v1/responses
```

Extended response format:

```bash
curl -X POST http://localhost:8080/v1/responses \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $OPENAI_API_KEY" \
  -d '{
    "model": "gpt-4",
    "input": "Hello!"
  }'
```

### List Models

```
GET /v1/models
```

Returns available models:

```json
{
  "object": "list",
  "data": [
    {"id": "gpt-4", "object": "model", "created": 1704067200, "owned_by": "openai"},
    {"id": "gpt-3.5-turbo", "object": "model", "created": 1704067200, "owned_by": "openai"}
  ]
}
```

### Metrics (Prometheus)

```
GET /metrics
```

Returns Prometheus-format metrics:

```
# HELP knot3bot_uptime_seconds Server uptime in seconds
# TYPE knot3bot_uptime_seconds gauge
knot3bot_uptime_seconds 3600

# HELP knot3bot_total_requests Total number of HTTP requests
# TYPE knot3bot_total_requests counter
knot3bot_total_requests 150

# HELP knot3bot_errors Total HTTP errors
# TYPE knot3bot_errors counter
knot3bot_errors 5

# HELP knot3bot_circuit_breaker_state Current circuit breaker state
# TYPE knot3bot_circuit_breaker_state gauge
knot3bot_circuit_breaker_state 0
```

## Authentication

### API Key Authentication

```bash
curl -H "Authorization: Bearer $OPENAI_API_KEY" \
  http://localhost:8080/v1/chat/completions ...
```

### Disabling Auth (Development)

```bash
# Set empty API key to disable auth
OPENAI_API_KEY="" knot3bot --server
```

## Rate Limiting

Default rate limits:

- **100 requests per minute** per IP
- **1000 requests per hour** per IP

## Circuit Breaker

The server implements circuit breaker pattern:

- **Closed**: Normal operation
- **Open**: Failing fast after 5 consecutive errors
- **Half-Open**: Testing recovery

Circuit breaker state is exposed in `/metrics`.

## Error Responses

### 400 Bad Request

```json
{
  "error": {
    "message": "Invalid request body",
    "type": "invalid_request_error",
    "code": "invalid_json"
  }
}
```

### 401 Unauthorized

```json
{
  "error": {
    "message": "Invalid API key",
    "type": "authentication_error"
  }
}
```

### 429 Too Many Requests

```json
{
  "error": {
    "message": "Rate limit exceeded",
    "type": "rate_limit_error",
    "retry_after": 60
  }
}
```

### 500 Internal Server Error

```json
{
  "error": {
    "message": "Internal server error",
    "type": "server_error"
  }
}
```

## WebSocket (Advanced)

WebSocket support for streaming responses:

```
ws://localhost:8080/ws
```

Connect and send JSON messages:

```json
{
  "type": "chat",
  "messages": [...],
  "stream": true
}
```

## Next Steps

- [Tools Reference](tools.md) — Available tools in server mode
- [Configuration](configuration.md) — Server configuration options
