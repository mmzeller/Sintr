#!/bin/bash
# For the automated tests: runs Sintr in an iPhone simulator at several text sizes, takes
# screenshots of the first screen, and saves them to the "screenshots" branch so they can
# be looked at without a phone.
set -uo pipefail
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
phones = [(runtime, d) for runtime, items in devices.items() if 'iOS' in runtime for d in items if d['name'].startswith('iPhone')]
plain = [p for p in phones if 'Max' not in p[1]['name'] and 'Plus' not in p[1]['name'] and 'Pro' not in p[1]['name']] or phones
plain.sort(key=lambda p: (p[0], p[1]['name']))
print(plain[-1][1]['udid'])")
NAME=$(xcrun simctl list devices | grep "$UDID" | sed 's/ (.*//' | xargs)
echo "Simulator: $NAME ($UDID)"

xcodebuild build -project Sintr.xcodeproj -scheme Sintr -configuration Debug \
  -destination "id=$UDID" -derivedDataPath build/sim \
  -skipPackagePluginValidation -skipMacroValidation CODE_SIGNING_ALLOWED=NO -quiet 2>&1 | grep -E "error:" | head -30
APP=build/sim/Build/Products/Debug-iphonesimulator/Sintr.app
[ -d "$APP" ] || { echo "::error title=Screenshots::The simulator build failed"; exit 1; }
BUNDLE=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Info.plist")

xcrun simctl boot "$UDID" 2>/dev/null
xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl status_bar "$UDID" override --time "9:41" --batteryLevel 100 --cellularBars 4 2>/dev/null
xcrun simctl install "$UDID" "$APP"
mkdir -p shots
for SIZE in large extra-extra-extra-large accessibility-medium accessibility-extra-large; do
  xcrun simctl ui "$UDID" content_size "$SIZE"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
  xcrun simctl launch "$UDID" "$BUNDLE" >/dev/null
  sleep 8
  xcrun simctl io "$UDID" screenshot "shots/setup-$SIZE.png" >/dev/null
done
ls -la shots

# Publish to the "screenshots" branch.
cd shots
printf 'Screenshots of %s on %s.\n' "$GITHUB_SHA" "$NAME" > README.md
git init -q && git checkout -q -b screenshots && git add . \
  && git -c user.name="Sintr CI" -c user.email="ci@users.noreply.github.com" commit -qm "Screenshots for $GITHUB_SHA" \
  && git push -qf "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" screenshots
echo "::notice title=Screenshots::Saved to the screenshots branch ($NAME)"
