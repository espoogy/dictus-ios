#!/bin/zsh
# Installs (or removes) the weekly Dictus auto-sign job for this Mac user.
#
#   Install:   zsh scripts/self-hosted/install-autosign.sh
#   Remove:    zsh scripts/self-hosted/install-autosign.sh --remove
set -euo pipefail

LABEL="io.aequari.dictus.autosign"
BASE="$HOME/Library/Application Support/DictusAutoSign"
APP="$BASE/Dictus AutoSign.app"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$BASE/autosign.sh"   # old location, from before the app bundle

if [[ "${1:-}" == "--remove" ]]; then
  rm -f "$PLIST"
  rm -rf "$APP"
  echo "Removed. (Log and build files in $BASE are kept.)"
  exit 0
fi

# launchd cannot run scripts inside ~/Documents, so copy the script out.
# It goes inside a tiny app bundle, so macOS shows "Dictus AutoSign" in
# System Settings > General > Login Items instead of "zsh".
mkdir -p "$APP/Contents/MacOS" "$HOME/Library/LaunchAgents"
cp "${0:A:h}/autosign.sh" "$APP/Contents/MacOS/dictus-autosign"
chmod 755 "$APP/Contents/MacOS/dictus-autosign"

/usr/libexec/PlistBuddy -c "Clear dict" \
  -c "Add :CFBundleIdentifier string $LABEL" \
  -c "Add :CFBundleName string 'Dictus AutoSign'" \
  -c "Add :CFBundleDisplayName string 'Dictus AutoSign'" \
  -c "Add :CFBundleExecutable string dictus-autosign" \
  -c "Add :CFBundlePackageType string APPL" \
  -c "Add :CFBundleVersion string 1" \
  -c "Add :LSUIElement bool true" \
  "$APP/Contents/Info.plist" >/dev/null 2>&1 || true

# Local signature only (not Apple-issued). It lets macOS tie the job to this bundle.
codesign --force --sign - --identifier "$LABEL" "$APP" >/dev/null 2>&1 || true

rm -f "$PLIST"
/usr/libexec/PlistBuddy \
  -c "Add :Label string $LABEL" \
  -c "Add :ProgramArguments array" \
  -c "Add :ProgramArguments:0 string $APP/Contents/MacOS/dictus-autosign" \
  -c "Add :AssociatedBundleIdentifiers array" \
  -c "Add :AssociatedBundleIdentifiers:0 string $LABEL" \
  -c "Add :StartInterval integer 14400" \
  -c "Add :RunAtLoad bool true" \
  "$PLIST" >/dev/null

launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed as \"Dictus AutoSign\". It checks every 4 hours. Log: $BASE/autosign.log"
