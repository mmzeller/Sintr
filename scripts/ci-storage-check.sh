#!/bin/bash
# For the automated tests: runs a built Sintr with --storage-check and reports what happened,
# including the crash report if it crashed. Usage: ci-storage-check.sh <Sintr.app> <label>
APP="$1"; LABEL="$2"
START=$(date +%s)
OUT=$(perl -e 'alarm 120; exec @ARGV' "$APP/Contents/MacOS/Sintr" --storage-check 2>&1)
CODE=$?
echo "$OUT"
REPORT=""
if [ $CODE -ne 0 ]; then
  sleep 5
  CRASH=$(ls -t ~/Library/Logs/DiagnosticReports/Sintr* 2>/dev/null | head -1)
  if [ -n "$CRASH" ]; then
    REPORT=$(python3 - "$CRASH" <<'PY'
import json, sys
text = open(sys.argv[1]).read()
try:
    header, body = text.split("\n", 1)
    d = json.loads(body)
    out = [f"exception: {d.get('exception')}", f"termination: {d.get('termination')}"]
    asi = d.get("asi") or {}
    for k, v in asi.items(): out.append(f"asi {k}: {v}")
    images = d.get("usedImages", [])
    t = next((t for t in d.get("threads", []) if t.get("triggered")), None)
    if t:
        for f in t.get("frames", [])[:30]:
            img = images[f["imageIndex"]].get("name", "?") if f.get("imageIndex") is not None and f["imageIndex"] < len(images) else "?"
            out.append(f"  {img}  {f.get('symbol', '?')}")
    print("\n".join(out))
except Exception as e:
    print(text[:3000])
PY
)
  fi
fi
echo "$REPORT"
MSG=$(printf 'exit %s\n%s\n%s' "$CODE" "$OUT" "$REPORT" | head -60 | sed -e 's/%/%25/g' | awk 'BEGIN{ORS="%0A"} {print}')
echo "::notice title=$LABEL::$MSG"
echo "$OUT" > "$RUNNER_TEMP/last-check.txt"
exit $CODE
