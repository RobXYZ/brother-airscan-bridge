#!/bin/zsh
# Stops the background service and removes everything install.sh put in place.
set -euo pipefail

LABEL=local.brother-airscan-bridge
SUPPORT="$HOME/Library/Application Support/brother-airscan-bridge"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist" "$SUPPORT/brother-airscan-bridge" \
      "$HOME/Library/Logs/brother-airscan-bridge.log"
rmdir "$SUPPORT" 2>/dev/null || true
echo "Uninstalled."
