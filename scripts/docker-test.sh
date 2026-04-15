#!/bin/bash
# Docker test script for knot3bot with 百练 (Bailian) API
#
# Usage:
#   ./docker-test.sh                    # Run tests only
#   ./docker-test.sh --server           # Run server with UI on port 8080
#   BAILIAN_API_KEY=xxx ./docker-test.sh --server  # Run with specific API key

set -e

PORT=8080

# Get API key from environment or use provided key
API_KEY="${BAILIAN_API_KEY:-baD31hkoqNK9ZL1iNVi0GjdljSsK3MFhV8QLYq9ZTzn0GwUqmUMRBsLdXDkkpBfU}"

echo "=== knot3bot Docker Test ==="
echo "API Key: ${API_KEY:0:10}..."
echo "Provider: Bailian (Alibaba)"
echo "Model: qwen-plus"
echo ""

# Check if running in server mode
if [[ "$1" == "--server" ]]; then
    echo "=== Starting server on port $PORT ==="
    echo "Access UI at: http://localhost:$PORT/ui"
    echo "Press Ctrl+C to stop"
    echo ""
    
    PWD="$(pwd)" BAILIAN_API_KEY="$API_KEY" ./zig-out/bin/knot3bot \
        --server \
        --port $PORT \
        --provider bailian
    
else
    echo "=== Running tests ==="
    zig build test
    echo ""
    echo "=== Tests passed ==="
    echo ""
    echo "To run server with UI:"
    echo "  ./scripts/docker-test.sh --server"
fi
