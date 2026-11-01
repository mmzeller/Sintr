#!/bin/bash
# For the automated tests: compiles the parts of Sintr that decide things for "Recognize voices",
# "Hide people's names from Claude" and meeting detection on their own, with a small test program,
# and runs it on this Mac (Apple's on-device name finder included):
#   Sintr/Speech/VoiceMatcher.swift    which remembered voice a speaker is
#   Sintr/AI/NameShield.swift          which words are names, and putting them back
#   Sintr/Audio/MeetingDetection.swift when a call starts and ends, and which app it's in
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${RUNNER_TEMP:-$(mktemp -d)}/logic-check"
rm -rf "$WORK"; mkdir -p "$WORK"
swiftc -Onone -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Sintr/Speech/VoiceMatcher.swift Sintr/AI/NameShield.swift Sintr/Audio/MeetingDetection.swift \
  scripts/logic-selftest.swift -o "$WORK/logic-selftest"
"$WORK/logic-selftest"
