#!/bin/zsh
# Installs (or removes) the weekly Dictus auto-sign job for this Mac user.
#
#   Install:   zsh scripts/self-hosted/install-autosign.sh
#   Remove:    zsh scripts/self-hosted/install-autosign.sh --remove
set -euo pipefail

LABEL="io.aequari.dictus.autosign"
BASE="$HOME/Library/Application Support/DictusAutoSign"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$PLIST"
  echo "Removed. (Files in $BASE are kept.)"
  exit 0
fi

# launchd cannot run scripts inside ~/Documents, so copy the script out.
mkdir -p "$BASE" "$HOME/Library/LaunchAgents"
cp "${0:A:h}/autosign.sh" "$BASE/autosign.sh"
chmod 755 "$BASE/autosign.sh"

cat >"$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/zsh</string><string>$BASE/autosign.sh</string></array>
  <key>StartInterval</key><integer>14400</integer>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
EOF

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed. It checks every 4 hours. Log: $BASE/autosign.log"
