#!/bin/bash
# Builds Sintr for this Mac, puts it in Applications and opens it.
# Do the "First time on your Mac" steps in the README once before using this
# (Xcode needs to know your signing team).
# Usage:  bash ~/Sintr/install-mac.sh
set -uo pipefail
cd "$(dirname "$0")"
PROJECT="Sintr.xcodeproj/project.pbxproj"

bold() { printf "\n\033[1m%s\033[0m\n" "$1"; }
red()  { printf "\n\033[1;31m%s\033[0m\n" "$1"; }

# 1. Use the full Xcode, even if Terminal is set to Apple's smaller Command Line Tools
#    (that's the usual setup after installing them for other projects).
if ! xcodebuild -version >/dev/null 2>&1; then
  XCODE=""
  if [ -d /Applications/Xcode.app ]; then
    XCODE=/Applications/Xcode.app
  else
    XCODE=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)
  fi
  if [ -z "$XCODE" ]; then
    red "Xcode isn't installed. Install it from the Mac App Store, open it once, then run this again."
    exit 1
  fi
  export DEVELOPER_DIR="$XCODE/Contents/Developer"
  if ! xcodebuild -version >/dev/null 2>&1; then
    red "Xcode is installed but isn't set up yet. Open Xcode once, let it finish installing its components, then run this again."
    exit 1
  fi
fi
echo "Using $(xcodebuild -version | head -1)"

# 2. Signing team (chosen once in Xcode)
TEAM=$(grep -oE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$PROJECT" | head -1 | grep -oE '[A-Z0-9]{10}' || true)
if [ -z "$TEAM" ]; then
  red "Pick your team in Xcode first: open Sintr.xcodeproj, click Sintr (blue icon) → Signing & Capabilities → Team."
  exit 1
fi

# 3. The phone model's code includes graphics-chip programs, which need Xcode's Metal
#    toolchain. Xcode 26 downloads it separately (about 700 MB, one time).
if ! xcrun metal --version >/dev/null 2>&1; then
  bold "Downloading Xcode's Metal toolchain (one time)…"
  if ! xcodebuild -downloadComponent MetalToolchain; then
    red "Couldn't download the Metal toolchain. In Xcode: Settings → Components → Metal Toolchain → Get, then run this again."
    exit 1
  fi
fi

# 4. Build
bold "Building Sintr for this Mac (the first build takes a few minutes)…"
if ! xcodebuild build \
    -project Sintr.xcodeproj -scheme Sintr -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath build \
    -allowProvisioningUpdates DEVELOPMENT_TEAM="$TEAM" \
    -quiet; then
  red "Build failed. Copy the lines above that say 'error' and paste them to Claude."
  exit 1
fi

# 5. Install and open
if pgrep -x Sintr >/dev/null; then
  osascript -e 'tell application id "io.github.mmzeller.Sintr" to quit' >/dev/null 2>&1 || true
  sleep 1
fi
rm -rf /Applications/Sintr.app
ditto build/Build/Products/Release/Sintr.app /Applications/Sintr.app
bold "Installed Sintr in Applications."
open /Applications/Sintr.app
