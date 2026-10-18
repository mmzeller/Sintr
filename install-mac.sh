#!/bin/bash
# Builds Sintr for this Mac, puts it in Applications and opens it.
# No Apple account needed. If you picked a signing team in Xcode (for the iPhone), the Mac
# app is signed with it too, so macOS remembers Sintr's permissions across updates; if that
# doesn't work (say Xcode's sign-in has expired), Sintr is built to run on this Mac only.
# Usage:  bash ~/Sintr/install-mac.sh
set -uo pipefail
cd "$(dirname "$0")"
PROJECT="Sintr.xcodeproj/project.pbxproj"
LOG="$(mktemp -t sintr-build)"

source scripts/common.sh

# 1. Find Xcode and make sure it has what the build needs
use_xcode || exit 1
ensure_metal_toolchain || exit 1

# Output goes to a log first, so a signing problem that's handled below doesn't look like a failure.
build_with_team() {
  xcodebuild build \
    -project Sintr.xcodeproj -scheme Sintr -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$1" \
    -quiet >"$LOG" 2>&1
}

build_for_this_mac() {
  xcodebuild build \
    -project Sintr.xcodeproj -scheme Sintr -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    ENABLE_HARDENED_RUNTIME=NO \
    -quiet
}

# 2. Build
TEAM=$(team_from_project "$PROJECT")
bold "Building Sintr for this Mac (the first build takes a few minutes)…"
if [ -n "$TEAM" ]; then
  if ! build_with_team "$TEAM"; then
    if grep -qiE 'sign|provision|log in|account|certificate|team|identifier' "$LOG"; then
      echo "Your Apple team ($TEAM) can't sign right now, so Sintr is built to run on this Mac only. That's fine."
      if grep -qiE 'log in|login' "$LOG"; then
        echo "(Xcode's saved Apple sign-in doesn't work any more. Remove it in Xcode → Settings → Accounts when you get a chance.)"
      fi
      build_for_this_mac || { red "Build failed. Copy the lines above that say 'error' and paste them to Claude."; exit 1; }
    else
      cat "$LOG"
      red "Build failed. Copy the lines above that say 'error' and paste them to Claude."
      exit 1
    fi
  fi
else
  build_for_this_mac || { red "Build failed. Copy the lines above that say 'error' and paste them to Claude."; exit 1; }
fi
rm -f "$LOG"

# 3. Install and open
if pgrep -x Sintr >/dev/null; then
  osascript -e 'tell application id "io.github.mmzeller.Sintr" to quit' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf /Applications/Sintr.app
ditto build/Build/Products/Release/Sintr.app /Applications/Sintr.app
bold "Installed Sintr in Applications."
open /Applications/Sintr.app
