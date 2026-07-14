#!/usr/bin/env bash
# install.sh — dependency check + setup for tmux-llm-dashboard.
# Idempotent; safe to re-run.
set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
STATE_DIR="${MMS_STATE_DIR:-$HOME/.local/state/tmux-llm-dashboard}"

ok=1
need() {
  if command -v "$1" >/dev/null 2>&1; then
    printf '  ✓ %s\n' "$1"
  else
    printf '  ✗ %s missing%s\n' "$1" "${2:+ — $2}"
    [ "${3:-required}" = "required" ] && ok=0
  fi
}

echo "Checking dependencies:"
need zsh    "the dashboard is a zsh script"
need tmux   "install via your package manager"
need bash   ""
need python3 ""
need curl   "needed for GLM/DeepSeek quota rows"
need nc     "needed for host-probe row (row 3)" optional
need npx    "needed only for the 7-day usage row (row 4)" optional

[ "$ok" = 1 ] || { echo; echo "Install the missing required tools and re-run."; exit 1; }

chmod +x "$DIR/status.sh" "$DIR"/helpers/*.sh
mkdir -p "$STATE_DIR"

echo
echo "Installed. State dir: $STATE_DIR"
echo
echo "Next steps:"
echo "  1. Provider keys (optional, per provider — see README):"
echo "       mkdir -p ~/.config/secrets && chmod 700 ~/.config/secrets"
echo "       echo 'KEY' > ~/.config/secrets/glm-api-key       # row 7"
echo "       echo 'KEY' > ~/.config/secrets/deepseek-api-key  # row 8"
echo "       chmod 600 ~/.config/secrets/*"
echo "  2. Sanity check:   $DIR/status.sh --all"
echo "  3. tmux binding (add to ~/.tmux.conf):"
echo "       bind-key D split-window -v -l 9 \"$DIR/status.sh --watch '#{pane_id}' '#{pane_current_path}'\""
