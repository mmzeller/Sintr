# Shared helpers for install-mac.sh and make-portable.sh. Not meant to be run on its own.

bold() { printf "\n\033[1m%s\033[0m\n" "$1"; }
red()  { printf "\n\033[1;31m%s\033[0m\n" "$1"; }

# Use the full Xcode, even if Terminal is set to Apple's smaller Command Line Tools
# (the usual setup after installing them for other projects).
use_xcode() {
  if ! xcodebuild -version >/dev/null 2>&1; then
    local xcode=""
    if [ -d /Applications/Xcode.app ]; then
      xcode=/Applications/Xcode.app
    else
      xcode=$(ls -d /Applications/Xcode*.app 2>/dev/null | sort -V | tail -1)
    fi
    if [ -z "$xcode" ]; then
      red "Xcode isn't installed. Install it from the Mac App Store, open it once, then run this again."
      return 1
    fi
    export DEVELOPER_DIR="$xcode/Contents/Developer"
    if ! xcodebuild -version >/dev/null 2>&1; then
      red "Xcode is installed but isn't set up yet. Open Xcode once, let it finish installing its components, then run this again."
      return 1
    fi
  fi
  echo "Using $(xcodebuild -version | head -1)"
}

# The phone model's code includes graphics-chip programs, which need Xcode's Metal
# toolchain. Xcode 26 downloads it separately (about 700 MB, one time).
ensure_metal_toolchain() {
  if ! xcrun metal --version >/dev/null 2>&1; then
    bold "Downloading Xcode's Metal toolchain (one time)…"
    if ! xcodebuild -downloadComponent MetalToolchain; then
      red "Couldn't download the Metal toolchain. In Xcode: Settings → Components → Metal Toolchain → Get, then run this again."
      return 1
    fi
  fi
}
