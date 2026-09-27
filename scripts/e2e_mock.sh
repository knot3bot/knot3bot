#!/bin/bash
# End-to-end smoke test: knot3bot server against a local mock LLM.
#
# Exercises the full stack — HTTP server → auth → agent ReAct loop →
# LLM client (incl. SSE streaming) → tool execution → second LLM round —
# without any real API key, via the OPENAI_BASE_URL override pointing at
# scripts/mock_llm.py.
#
# Usage: scripts/e2e_mock.sh [port]
set -u
cd "$(dirname "$0")/.."

PORT="${1:-8123}"
MOCK_PORT=$((PORT + 1))
BOT_LOG=$(mktemp)
cleanup() { kill "${MOCK_PID:-}" "${BOT_PID:-}" 2>/dev/null; rm -f "$BOT_LOG"; }
trap cleanup EXIT

fail() {
  echo "E2E FAIL: $1"
  echo "--- bot log ---"
  cat "$BOT_LOG" 2>/dev/null || true
  exit 1
}

python3 scripts/mock_llm.py "$MOCK_PORT" &
MOCK_PID=$!
sleep 0.5

OPENAI_API_KEY=test-key \
OPENAI_BASE_URL="http://127.0.0.1:$MOCK_PORT/v1" \
./zig-out/bin/knot3bot --server --port "$PORT" > "$BOT_LOG" 2>&1 &
BOT_PID=$!

# Wait for the server to come up (poll /health, up to 30s)
UP=0
for i in $(seq 1 60); do
  CODE=$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/health" 2>/dev/null)
  if [ "$CODE" = "200" ]; then UP=1; break; fi
  sleep 0.5
done
if [ "$UP" != "1" ]; then
  echo "E2E FAIL: server did not become healthy; bot log:"
  cat "$BOT_LOG"
  exit 1
fi

URL="http://127.0.0.1:$PORT/v1/chat/completions"
AUTH="Authorization: Bearer test-key"

# 1) auth rejected without credentials (exit 41 = this stage failed)
CODE=$(curl -s -m 10 -o /dev/null -w '%{http_code}' -X POST "$URL" \
  -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hi"}]}')
[ "$CODE" = "401" ] || { echo "expected 401 without auth, got $CODE"; exit 41; }
echo "PASS: auth rejects unauthenticated requests"

# 2) non-stream chat round trip
R=$(curl -s -m 30 -X POST "$URL" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hi there"}]}')
echo "$R" | grep -q "Hello from mock LLM" || { echo "non-stream chat: $R"; exit 42; }
echo "PASS: non-stream chat round trip"

# 3) streaming SSE
S=$(curl -s -N -m 30 -X POST "$URL" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"Hello"}],"stream":true}')
echo "$S" | grep -q "\[DONE\]" || { echo "stream missing [DONE]: $S"; exit 43; }
echo "$S" | grep -q "Hello" || { echo "stream missing content: $S"; exit 43; }
echo "PASS: streaming SSE"

# 4) tool-calling round trip (mock invokes the real calculator tool)
T=$(curl -s -m 60 -X POST "$URL" -H "$AUTH" -H "Content-Type: application/json" \
  -d '{"model":"gpt-4o","messages":[{"role":"user","content":"please use the calculator tool to compute 4 times 7"}]}')
echo "$T" | grep -qE "Tool result:.*28" || { echo "tool round trip: $T"; exit 44; }
echo "PASS: tool-calling round trip (calculator 4*7)"

echo "E2E PASS"
