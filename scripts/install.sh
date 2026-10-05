#!/bin/zsh
# Builds the bridge and installs it as a per-user background service that starts at login.
# No sudo needed. Extra arguments are passed to the bridge, e.g.:
#   scripts/install.sh --host 192.168.1.50
set -euo pipefail

LABEL=local.brother-airscan-bridge
DOMAIN="gui/$(id -u)"
SUPPORT="$HOME/Library/Application Support/brother-airscan-bridge"
BIN="$SUPPORT/brother-airscan-bridge"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/brother-airscan-bridge.log"

cd "${0:A:h}/.."
swift build -c release

# bootout returns before the service has gone; wait so the bootstrap below doesn't collide.
if launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null; then
  for _ in {1..50}; do
    launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
    sleep 0.1
  done
fi

mkdir -p "$SUPPORT" "${PLIST:h}" "${LOG:h}"
install -m 755 .build/release/brother-airscan-bridge "$BIN"

plutil -create xml1 "$PLIST"
plutil -insert Label -string "$LABEL" "$PLIST"
plutil -insert ProgramArguments -array "$PLIST"
for argument in "$BIN" "$@"; do
  plutil -insert ProgramArguments -string "$argument" -append "$PLIST"
done
plutil -insert RunAtLoad -bool true "$PLIST"
plutil -insert KeepAlive -bool true "$PLIST"
plutil -insert ProcessType -string Background "$PLIST"
plutil -insert StandardErrorPath -string "$LOG" "$PLIST"
plutil -insert StandardOutPath -string "$LOG" "$PLIST"

launchctl bootstrap "$DOMAIN" "$PLIST"
echo "Installed and running. Log: $LOG"
