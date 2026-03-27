#!/bin/sh
# claude-statusline installer
# Copies statusline.sh to ~/.claude/ and configures settings.json

set -e

CLAUDE_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Check dependencies
if ! command -v jq >/dev/null 2>&1; then
  echo "Error: jq is required. Install it:"
  echo "  macOS:  brew install jq"
  echo "  Ubuntu: sudo apt install jq"
  echo "  Arch:   sudo pacman -S jq"
  exit 1
fi

# Create ~/.claude if needed
mkdir -p "$CLAUDE_DIR"

# Copy statusline script
cp "$SCRIPT_DIR/statusline.sh" "$CLAUDE_DIR/statusline-command.sh"
chmod +x "$CLAUDE_DIR/statusline-command.sh"
echo "Installed statusline-command.sh → $CLAUDE_DIR/"

# Copy example config (don't overwrite existing)
if [ ! -f "$CLAUDE_DIR/statusline.conf" ]; then
  cp "$SCRIPT_DIR/statusline.conf.example" "$CLAUDE_DIR/statusline.conf"
  echo "Created statusline.conf → $CLAUDE_DIR/"
else
  echo "Skipped statusline.conf (already exists)"
fi

# Configure settings.json
SETTINGS="$CLAUDE_DIR/settings.json"
if [ ! -f "$SETTINGS" ]; then
  echo '{}' > "$SETTINGS"
fi

# Check if statusLine is already configured
if jq -e '.statusLine' < "$SETTINGS" >/dev/null 2>&1; then
  echo ""
  printf "statusLine already configured in settings.json. Overwrite? [y/N] "
  read -r answer
  if [ "$answer" != "y" ] && [ "$answer" != "Y" ]; then
    echo "Skipped settings.json update"
    echo ""
    echo "Done! Restart Claude Code to see your statusline."
    exit 0
  fi
fi

# Add statusLine config
tmp=$(mktemp)
jq '.statusLine = {"type": "command", "command": "sh ~/.claude/statusline-command.sh"}' "$SETTINGS" > "$tmp"
mv "$tmp" "$SETTINGS"
echo "Updated settings.json with statusLine config"

echo ""
echo "Done! Restart Claude Code to see your statusline."
