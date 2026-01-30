#!/usr/bin/env bash
set -e

echo "=== DevContainer Post-Create Setup ==="

# Install OpenCode CLI
echo "Installing OpenCode..."
curl -fsSL https://opencode.ai/install | bash

# Add opencode to PATH for current session
export PATH="$HOME/.opencode/bin:$PATH"

# Install Oh-My-OpenCode (non-interactive)
echo "Installing Oh-My-OpenCode..."
bunx oh-my-opencode install --no-tui --claude=no --gemini=no --copilot=no

# Validate environment
echo ""
echo "=== Environment Validation ==="
echo -n "debootstrap: " && (command -v debootstrap && echo "OK") || echo "MISSING"
echo -n "xorriso: " && (command -v xorriso && echo "OK") || echo "MISSING"
echo -n "shellcheck: " && (command -v shellcheck && echo "OK") || echo "MISSING"
echo -n "bats: " && (command -v bats && echo "OK") || echo "MISSING"
echo -n "opencode: " && (command -v opencode && echo "OK") || echo "MISSING"

echo ""
echo "=== DevContainer Setup Complete ==="
