#!/bin/bash
# For the automated tests: runs Sintr in an iPhone simulator at several text sizes, takes
# screenshots of the first screen, and saves them to the "screenshots" branch so they can
# be looked at without a phone.
set -uo pipefail
UDID=$(xcrun simctl list devices available -j | python3 -c "
import json, sys
devices = json.load(sys.stdin)['devices']
phones = [(runtime, d) for runtime, items in devices.items() if 'iOS' in runtime for d in items if d['name'].startswith('iPhone')]
# The same width as an iPhone 12 (390 points) where possible.
preferred = ['iPhone 16e', 'iPhone 17', 'iPhone 16', 'iPhone 15']
phones.sort(key=lambda p: p[0], reverse=True)
for name in preferred:
    match = [p for p in phones if p[1]['name'] == name]
    if match:
        print(match[0][1]['udid']); break
else:
    print(phones[0][1]['udid'])")
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
  sleep 15
  xcrun simctl io "$UDID" screenshot "shots/setup-$SIZE.png" >/dev/null
done

# Sample notes (see ScreenshotDemo.swift): enhanced, new, Review & send for Sectis, a short
# enhanced note showing the Sectis card, one whose to-dos went to Sectis (the card lists them),
# an empty Enhanced tab, and the Transcript tab with detected speakers and the "Transcript
# rebuilt" message.
for MODE in enhanced new review card sent empty transcript; do
  for SIZE in large extra-extra-extra-large accessibility-medium; do
    xcrun simctl ui "$UDID" content_size "$SIZE"
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
    xcrun simctl launch "$UDID" "$BUNDLE" --demo-note "$MODE" >/dev/null
    sleep 12
    xcrun simctl io "$UDID" screenshot "shots/note-$MODE-$SIZE.png" >/dev/null
  done
done

# The same note screen 320 points wide — an iPhone 12 with Display Zoom set to Larger Text,
# where the screen is narrower than any simulator's. Anything wider than that screen shows past
# the red lines at its edges.
for MODE in transcript enhanced new; do
  for SIZE in large extra-extra-extra-large accessibility-medium; do
    xcrun simctl ui "$UDID" content_size "$SIZE"
    xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
    xcrun simctl launch "$UDID" "$BUNDLE" --demo-note "$MODE" --demo-width 320 >/dev/null
    sleep 12
    xcrun simctl io "$UDID" screenshot "shots/zoomed-$MODE-$SIZE.png" >/dev/null
  done
done
# sintr:// links, the way Sectis opens them (SintrLinks.swift): a note that's here, a new note
# for a Sectis project (Sintr asks before recording), and a note that isn't on this phone.
# "prompt" is a real link from outside: iOS asks "Open in Sintr?", which shows the scheme is
# registered; the others go straight to Sintr's handler (--demo-link), past that question.
xcrun simctl ui "$UDID" content_size large
for LINK in "note|sintr://note/5A5A5A5A-0000-4000-8000-000000000001" \
            "new|sintr://new?title=Weekly%20sync&place=project:demoproj1&placeTitle=Q4%20streaming%20upgrade&sectis=https%3A%2F%2Fexample.github.io%2Fsectis%2F" \
            "missing|sintr://note/00000000-0000-4000-8000-0000000000AA"; do
  NAME_PART="${LINK%%|*}"; URL="${LINK#*|}"
  xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
  xcrun simctl launch "$UDID" "$BUNDLE" --demo-note card --demo-link "$URL" >/dev/null
  sleep 14
  xcrun simctl io "$UDID" screenshot "shots/link-$NAME_PART.png" >/dev/null
done
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
xcrun simctl launch "$UDID" "$BUNDLE" --demo-note card >/dev/null
sleep 10
xcrun simctl openurl "$UDID" "sintr://note/5A5A5A5A-0000-4000-8000-000000000001" || echo "::warning title=Links::openurl failed"
sleep 5
xcrun simctl io "$UDID" screenshot "shots/link-prompt.png" >/dev/null

ls -la shots

# The iPhone layout check (PhoneLayoutCheck.swift): measures every tab of the note screen and
# the record bar at 320, 375 and 390 points and several text sizes; nothing may be wider than
# the screen.
xcrun simctl terminate "$UDID" "$BUNDLE" 2>/dev/null
xcrun simctl ui "$UDID" content_size large
LAYOUT=$(perl -e 'alarm 180; exec @ARGV' xcrun simctl launch --console "$UDID" "$BUNDLE" --layout-check 2>&1)
echo "$LAYOUT" | grep -E "points|TOO WIDE|Control|RESULT|layout check" || echo "$LAYOUT" | tail -40
LAYOUT_STATUS=0
echo "$LAYOUT" | grep -q "RESULT: everything fits" || LAYOUT_STATUS=1
SUMMARY=$(echo "$LAYOUT" | grep -E "TOO WIDE|Control|RESULT" | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
if [ $LAYOUT_STATUS -eq 0 ]; then
  echo "::notice title=iPhone layout check::${SUMMARY}"
else
  echo "::error title=iPhone layout check::${SUMMARY:-The check did not finish (no RESULT line)}"
fi
echo "$LAYOUT" > shots/layout-check.txt

# Publish to the "screenshots" branch.
cd shots
printf 'Screenshots of %s on %s.\n' "$GITHUB_SHA" "$NAME" > README.md
git init -q && git checkout -q -b screenshots && git add . \
  && git -c user.name="Sintr CI" -c user.email="ci@users.noreply.github.com" commit -qm "Screenshots for $GITHUB_SHA" \
  && git push -qf "https://x-access-token:${GITHUB_TOKEN}@github.com/${GITHUB_REPOSITORY}.git" screenshots
echo "::notice title=Screenshots::Saved to the screenshots branch ($NAME)"
exit $LAYOUT_STATUS
