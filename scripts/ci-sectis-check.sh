#!/bin/bash
# For the automated tests: checks that Sintr reads and writes Sectis's sync format exactly the
# way Sectis does, and that the action-item reader finds the right items in sample notes.
#  1. Compiles Sintr/Transfer/SectisFormat.swift and SectisCloud.swift on their own with a
#     small test program, and round-trips a join code and encrypted records with Sectis's own
#     WebCrypto code in Node.
#  2. Runs the same program against the Firestore emulator with Sectis's security rules, then
#     reads what it wrote with the Firebase SDK and query Sectis uses.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="${RUNNER_TEMP:-$(mktemp -d)}/sectis-check"
rm -rf "$WORK"; mkdir -p "$WORK"

echo "== Compile"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  Sintr/Transfer/SectisFormat.swift Sintr/Transfer/SectisCloud.swift scripts/sectis-selftest.swift \
  -o "$WORK/sectis-selftest"

echo "== Format, encryption and action items"
node scripts/sectis-check.mjs make "$WORK/fixture.json"
"$WORK/sectis-selftest" "$WORK/fixture.json" "$WORK/sintr.json"
node scripts/sectis-check.mjs verify "$WORK/fixture.json" "$WORK/sintr.json"

echo "== Firestore emulator with Sectis's rules"
# The rules from Sectis's README, word for word.
cat > "$WORK/firestore.rules" <<'RULES'
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /sectis/{space}/items/{item} {
      allow read: if space.size() >= 40;
      allow create, update: if space.size() >= 40
        && request.resource.data.keys().hasOnly(['k', 'm', 'd', 'c', 'iv', 't'])
        && request.resource.data.c is string
        && request.resource.data.c.size() < 500000;
    }
  }
}
RULES
cat > "$WORK/firebase.json" <<'JSON'
{
  "firestore": { "rules": "firestore.rules" },
  "emulators": { "firestore": { "host": "127.0.0.1", "port": 8085 }, "ui": { "enabled": false } }
}
JSON
npm install --silent --no-save --no-audit --no-fund --prefix "$WORK/npm" firebase@10.14.1 firebase-tools@14 >/dev/null
export SECTIS_NODE_MODULES="$WORK/npm/node_modules"
"$WORK/npm/node_modules/.bin/firebase" emulators:exec --config "$WORK/firebase.json" --only firestore --project demo-sectis \
  "\"$WORK/sectis-selftest\" \"$WORK/fixture.json\" \"$WORK/sintr.json\" && node scripts/sectis-check.mjs listen \"$WORK/fixture.json\" \"$WORK/sintr.json\""
echo "Sectis checks passed."
