#!/usr/bin/env python3
"""Minimal OpenAI-compatible mock LLM for knot3bot end-to-end tests.

Serves POST .../chat/completions with three scripted behaviours:
  1. if the conversation already contains a tool result  -> final answer
     embedding that result (closes the tool-calling round trip)
  2. elif the last user message mentions the calculator   -> a tool_calls
     response invoking the real `calculator` tool (expression 4*7)
  3. otherwise                                            -> plain text

Used by scripts/e2e_mock.sh; no real API key required.
"""
import json
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("MOCK: " + (fmt % args) + "\n")

    def do_POST(self):
        if not self.path.endswith("/chat/completions"):
            self.send_response(404)
            self.end_headers()
            return
        length = int(self.headers.get("Content-Length", 0))
        body = json.loads(self.rfile.read(length) or b"{}")
        messages = body.get("messages", [])
        stream = bool(body.get("stream", False))

        tool_msg = next((m for m in messages if m.get("role") == "tool"), None)
        assistant_called = any(
            m.get("role") == "assistant" and m.get("tool_calls") for m in messages
        )
        last_user = next(
            (m.get("content", "") for m in reversed(messages) if m.get("role") == "user"),
            "",
        )

        if tool_msg is not None or assistant_called:
            tool_out = (tool_msg or {}).get("content", "")
            content = f"Mock final answer. Tool result: {tool_out}"
            self.send_completion(body, content, stream)
        elif "calculator" in str(last_user).lower():
            self.send_tool_call(body)
        else:
            self.send_completion(body, "Hello from mock LLM", stream)

    def send_completion(self, body, content, stream):
        model = body.get("model", "mock")
        if not stream:
            payload = {
                "id": "mock-1",
                "object": "chat.completion",
                "created": 0,
                "model": model,
                "choices": [{
                    "index": 0,
                    "message": {"role": "assistant", "content": content},
                    "finish_reason": "stop",
                }],
            }
            data = json.dumps(payload).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for word in content.split(" "):
            chunk = {
                "id": "mock-1",
                "object": "chat.completion.chunk",
                "model": model,
                "choices": [{
                    "index": 0,
                    "delta": {"content": word + " "},
                    "finish_reason": None,
                }],
            }
            self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            self.wfile.flush()
        done = {
            "id": "mock-1",
            "object": "chat.completion.chunk",
            "model": model,
            "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}],
        }
        self.wfile.write(f"data: {json.dumps(done)}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()

    def send_tool_call(self, body):
        payload = {
            "id": "mock-2",
            "object": "chat.completion",
            "created": 0,
            "model": body.get("model", "mock"),
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [{
                        "id": "call_mock_1",
                        "type": "function",
                        "function": {
                            "name": "calculator",
                            "arguments": '{"expression":"4*7"}',
                        },
                    }],
                },
                "finish_reason": "tool_calls",
            }],
        }
        data = json.dumps(payload).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8124
    HTTPServer(("127.0.0.1", port), Handler).serve_forever()


if __name__ == "__main__":
    main()
