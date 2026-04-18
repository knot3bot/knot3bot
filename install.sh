#!/bin/bash
# Install script for knot3bot

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  knot3bot Installation${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

# Check if Zig is installed
if ! command -v zig &> /dev/null; then
    echo -e "${RED}Error: Zig is not installed${NC}"
    echo ""
    echo "Please install Zig 0.15+ from https://ziglang.org/download/"
    echo ""
    exit 1
fi

ZIG_VERSION=$(zig version)
echo -e "${GREEN}✓ Found Zig: $ZIG_VERSION${NC}"
echo ""

# Default installation prefix
PREFIX="/usr/local"
if [ "$(id -u)" != "0" ]; then
    PREFIX="$HOME/.local"
    echo -e "${YELLOW}Note: Running as non-root, installing to $PREFIX${NC}"
    echo ""
fi

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --prefix)
            PREFIX="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Install knot3bot to your system"
            echo ""
            echo "Options:"
            echo "  --prefix PATH   Installation prefix (default: $PREFIX)"
            echo "  -h, --help      Show this help message"
            echo ""
            exit 0
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            exit 1
            ;;
    esac
done

echo -e "${BLUE}Installation prefix: $PREFIX${NC}"
echo ""

# Build knot3bot
echo -e "${BLUE}Building knot3bot (ReleaseFast)...${NC}"
zig build --release=fast

echo ""
echo -e "${GREEN}✓ Build successful${NC}"
echo ""

# Create directories
BINDIR="$PREFIX/bin"
DATADIR="$PREFIX/share/knot3bot"

echo -e "${BLUE}Creating directories...${NC}"
mkdir -p "$BINDIR"
mkdir -p "$DATADIR"

# Install binary
echo -e "${BLUE}Installing binary to $BINDIR...${NC}"
cp zig-out/bin/knot3bot "$BINDIR/"
chmod +x "$BINDIR/knot3bot"

# Create k3b alias
ln -sf "$BINDIR/knot3bot" "$BINDIR/k3b" 2>/dev/null || true

# Install configuration wizard if it exists
if [ -f "configure.py" ]; then
    echo -e "${BLUE}Installing configuration wizard...${NC}"
    cp configure.py "$BINDIR/k3b-configure"
    chmod +x "$BINDIR/k3b-configure"
fi

# Install UI files if they exist
if [ -d "ui" ]; then
    echo -e "${BLUE}Installing UI files to $DATADIR...${NC}"
    cp -r ui/* "$DATADIR/" 2>/dev/null || true
fi

echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  Installation Complete!${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "${BLUE}knot3bot is now available at:${NC}"
echo -e "  ${GREEN}$BINDIR/knot3bot${NC}"
echo -e "  ${GREEN}$BINDIR/k3b${NC} (alias)"

# Check if in PATH
if [[ ":$PATH:" != *":$BINDIR:"* ]]; then
    echo -e "${YELLOW}Note: $BINDIR is not in your PATH${NC}"
    echo ""
    echo "To add it temporarily:"
    echo "  export PATH=\"$BINDIR:\$PATH\""
    echo ""
    echo "To add it permanently, add the above line to your ~/.bashrc or ~/.zshrc"
    echo ""
fi

echo -e "${BLUE}Quick Start:${NC}"
echo ""
echo "  # Run in CLI mode"
echo "  knot3bot  # or: k3b"
echo ""
echo "  # Run server mode"
echo "  knot3bot --server --port 8080  # or: k3b --server --port 8080"
echo ""
echo "  # Configure knot3bot"
echo "  k3b-configure  # or: knot3bot configure"
echo ""
echo "  # Show help"
echo "  knot3bot --help  # or: k3b --help"
echo -e "${GREEN}Enjoy using knot3bot!${NC}"
echo ""
