#!/bin/bash
# For the automated tests: compiles Sintr/Audio/AudioProcesses.swift on its own and checks it on
# this Mac — which processes belong to an app (Safari's media helper, Chrome's helpers) and the
# system lookups behind that (libproc, the responsible-process call, Core Audio's process list).
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${RUNNER_TEMP:-$(mktemp -d)}/audio-check"
rm -rf "$WORK"; mkdir -p "$WORK"
swiftc -Onone -parse-as-library -target "$(uname -m)-apple-macos14.2" \
  Sintr/Audio/AudioProcesses.swift scripts/audio-selftest.swift -o "$WORK/audio-selftest"
"$WORK/audio-selftest"
