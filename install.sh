#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SOURCE="$SCRIPT_DIR/skills/chat-mode"

if [[ ! -d "$SKILL_SOURCE" ]]; then
  echo "error: missing skill source: $SKILL_SOURCE" >&2
  exit 1
fi

if [[ -n "${CODEX_HOME:-}" ]]; then
  SKILLS_ROOT="$CODEX_HOME/skills"
else
  SKILLS_ROOT="$HOME/.codex/skills"
fi

SKILL_TARGET="$SKILLS_ROOT/chat-mode"
mkdir -p "$SKILL_TARGET"
cp -R "$SKILL_SOURCE/." "$SKILL_TARGET/"

echo "chat-mode skill installed successfully."
echo "Source: $SKILL_SOURCE"
echo "Target: $SKILL_TARGET"
echo "Restart Codex to load the updated skill."
echo "Note: the tested Claude Desktop UI Automation adapter is Windows-only."
