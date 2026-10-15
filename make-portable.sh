#!/bin/bash
# Builds a portable Sintr: a "Sintr Portable" folder that holds Sintr.app and a
# "Sintr Data" folder with your notes. Put it on a thumb drive or in any folder and
# double-click Sintr.app — notes, recordings and settings stay inside that folder.
#
# Usage:
#   bash ~/Sintr/make-portable.sh                       makes ~/Sintr Portable
#   bash ~/Sintr/make-portable.sh /Volumes/MYDRIVE      makes it on the thumb drive
#   (Tip: type the command, a space, then drag the drive or folder into Terminal.)
#
# Run it again with the same place to update the app. Your notes are always kept.
# No Apple ID or signing team needed: the app is signed just for running locally.
set -uo pipefail
cd "$(dirname "$0")"
source scripts/common.sh

# 1. Where to put it
TARGET="${1:-$HOME}"
TARGET="${TARGET%/}"
if [ ! -d "$TARGET" ]; then
  red "There's no folder or drive at: $TARGET"
  echo "Plug the drive in (it shows up under /Volumes), or check the folder name, then try again."
  exit 1
fi
if [ "$(basename "$TARGET")" = "Sintr Portable" ]; then
  DEST="$TARGET"
else
  DEST="$TARGET/Sintr Portable"
fi
mkdir -p "$DEST" 2>/dev/null
if [ ! -w "$DEST" ]; then
  red "Can't write to $DEST"
  echo "If it's a thumb drive, it may be locked or formatted for Windows only (NTFS). See “Portable version” in the README."
  exit 1
fi

# 2. Build (Apple-silicon Macs, signed for running locally)
use_xcode || exit 1
ensure_metal_toolchain || exit 1

bold "Building portable Sintr (the first build takes a while)…"
BUILD_DIR="build/portable"
if ! xcodebuild build \
    -project Sintr.xcodeproj -scheme Sintr -configuration Release \
    -destination "generic/platform=macOS" -derivedDataPath "$BUILD_DIR" \
    ARCHS=arm64 ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    ENABLE_HARDENED_RUNTIME=NO \
    -quiet; then
  red "Build failed. Copy the lines above that say 'error' and paste them to Claude."
  exit 1
fi
APP="$BUILD_DIR/Build/Products/Release/Sintr.app"

# 3. Put the app in place, keeping whatever is already in Sintr Data
if pgrep -f "$DEST/Sintr.app/Contents/MacOS/Sintr" >/dev/null 2>&1; then
  echo "Quitting the portable Sintr that's running…"
  pkill -f "$DEST/Sintr.app/Contents/MacOS/Sintr" 2>/dev/null || true
  sleep 2
fi
rm -rf "$DEST/Sintr.app"
# --noextattr --norsrc: don't leave macOS's hidden "._" files on exFAT/FAT thumb drives.
if ! ditto --norsrc --noextattr "$APP" "$DEST/Sintr.app"; then
  red "Couldn't copy Sintr.app to $DEST (is the drive full?)."
  exit 1
fi
mkdir -p "$DEST/Sintr Data"

cat > "$DEST/About Sintr Portable.txt" <<'TXT'
Sintr Portable
==============

Double-click Sintr.app to open it. Your notes, recordings and settings are saved in the
"Sintr Data" folder right here, so this whole folder can live on a thumb drive or anywhere.

- Keep Sintr.app and "Sintr Data" together in this folder.
- Quit Sintr before you eject the drive.
- Works on Macs with Apple silicon (M1 or newer) running macOS 26 or newer.
- The first time on each Mac, macOS asks to let Sintr use the microphone, record system
  audio and (on a thumb drive) use files on a removable volume. Sintr also asks once per Mac
  to download Apple's speech model. Your Claude key, if you use one, stays on each Mac.
- Back up "Sintr Data" now and then: if the drive is lost or fails, so are the notes on it.
TXT

# 4. First time: offer to bring this Mac's notes along
EXISTING=$(ls "$DEST/Sintr Data/Notes" 2>/dev/null | grep -v '^\._' | grep -c '\.json$' || true)
if [ "${EXISTING:-0}" -eq 0 ] && [ -t 0 ]; then
  for SRC in "$HOME/Library/Application Support/Sintr" \
             "$HOME/Library/Containers/io.github.mmzeller.Sintr/Data/Library/Application Support/Sintr"; do
    COUNT=$(ls "$SRC/Notes" 2>/dev/null | grep -c '\.json$' || true)
    if [ "${COUNT:-0}" -gt 0 ]; then
      printf "\nThis Mac has %s Sintr note(s). Copy them into the portable folder too? (y/n) " "$COUNT"
      read -r ANSWER
      if [[ "$ANSWER" =~ ^[Yy] ]]; then
        for SUB in Notes Recordings; do
          [ -d "$SRC/$SUB" ] && ditto --norsrc --noextattr "$SRC/$SUB" "$DEST/Sintr Data/$SUB"
        done
        echo "Copied. The originals on this Mac are untouched."
      fi
      break
    fi
  done
fi

SIZE=$(du -sh "$DEST" 2>/dev/null | cut -f1)
bold "Done. Portable Sintr is in: $DEST  ($SIZE)"
echo "Open it by double-clicking Sintr.app inside that folder."
[ -t 1 ] && open "$DEST"
exit 0
