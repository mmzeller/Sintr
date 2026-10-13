#!/bin/bash
# Builds Sintr for this Mac, puts it in Applications and opens it.
# Do the "First time on your Mac" steps in the README once before using this
# (Xcode needs to know your signing team).
# Usage:  bash ~/Sintr/install-mac.sh
set -uo pipefail
cd "$(dirname "$0")"
PROJECT="Sintr.xcodeproj/project.pbxproj"

TEAM=$(grep -oE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$PROJECT" | head -1 | grep -oE '[A-Z0-9]{10}' || true)
if [ -z "$TEAM" ]; then
  printf "\n\033[1;31m%s\033[0m\n" "Pick your team in Xcode first: open Sintr.xcodeproj, click Sintr (blue icon) → Signing & Capabilities → Team."
  exit 1
fi

printf "\n\033[1m%s\033[0m\n" "Building Sintr for this Mac (the first build takes a few minutes)…"
if ! xcodebuild build \
    -project Sintr.xcodeproj -scheme Sintr -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
    -quiet; then
  printf "\n\033[1;31m%s\033[0m\n" "Build failed. Copy the lines above that say 'error' and paste them to Claude."
  exit 1
fi

if pgrep -x Sintr >/dev/null; then
  osascript -e 'tell application id "io.github.mmzeller.Sintr" to quit' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf /Applications/Sintr.app
ditto build/Build/Products/Release/Sintr.app /Applications/Sintr.app
printf "\n\033[1m%s\033[0m\n" "Installed Sintr in Applications."
open /Applications/Sintr.app
