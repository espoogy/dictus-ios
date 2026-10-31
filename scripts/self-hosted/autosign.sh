#!/bin/zsh
# Dictus auto-sign (self-hosted fork).
#
# A free Apple ID signs apps for 7 days only. This script builds Dictus again from
# the espoogy fork and installs it on the iPhone over Wi-Fi, so the app never expires.
# It uses only Apple's own tools (xcodebuild, devicectl) and the Apple ID that is
# already signed in to Xcode. No password is stored here.
#
# launchd runs it every 4 hours. It does nothing unless the last good install is
# more than 5 days old, so it has 2 days to find the phone on Wi-Fi.
#
# Run it by hand:   FORCE=1 ~/Library/Application\ Support/DictusAutoSign/autosign.sh
# Log:              ~/Library/Application Support/DictusAutoSign/autosign.log

set -euo pipefail

export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

BASE="$HOME/Library/Application Support/DictusAutoSign"
SRC="$BASE/src"
LOG="$BASE/autosign.log"
STAMP="$BASE/last-success"
REPO="https://github.com/espoogy/dictus-ios.git"
BRANCH="self-hosted"
DEVICE="${DICTUS_DEVICE:-BD3CC89F-741F-5310-9393-000CA0C2CD7B}"   # Josh's iPhone
MAX_AGE_DAYS=5

mkdir -p "$BASE"
exec >>"$LOG" 2>&1
echo "=== $(date)"

notify() {
  /usr/bin/osascript -e "display notification \"$1\" with title \"Dictus auto-sign\"" || true
}
trap 'echo "FAILED"; notify "Re-sign failed. Open the log: ~/Library/Application Support/DictusAutoSign/autosign.log"' ERR

# Skip if the last good install is recent.
if [[ -z "${FORCE:-}" && -f "$STAMP" && -n "$(find "$STAMP" -mtime -${MAX_AGE_DAYS})" ]]; then
  echo "Last install is less than ${MAX_AGE_DAYS} days old. Nothing to do."
  exit 0
fi

# Skip quietly if the phone is not on the network right now. The next run tries again.
if ! xcrun devicectl list devices 2>/dev/null | grep "$DEVICE" | grep -q "available"; then
  echo "iPhone not reachable. Will try again later."
  exit 0
fi

# Get the newest code from your fork.
if [[ ! -d "$SRC/.git" ]]; then
  git clone --branch "$BRANCH" "$REPO" "$SRC"
fi
git -C "$SRC" fetch origin "$BRANCH"
git -C "$SRC" reset --hard "origin/$BRANCH"
echo "Building commit $(git -C "$SRC" rev-parse --short HEAD)"

# Build and sign. -disableAutomaticPackageResolution forces the exact library
# versions in Package.resolved, the ones that were checked.
xcodebuild build \
  -project "$SRC/Dictus.xcodeproj" \
  -scheme DictusApp \
  -configuration Release \
  -destination "generic/platform=iOS" \
  -derivedDataPath "$BASE/build" \
  -clonedSourcePackagesDirPath "$BASE/packages" \
  -disableAutomaticPackageResolution \
  -allowProvisioningUpdates \
  -quiet

APP="$BASE/build/Build/Products/Release-iphoneos/DictusApp.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"

touch "$STAMP"
echo "OK"
notify "Dictus re-installed. Good for 7 more days."
