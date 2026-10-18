#!/bin/bash
# For the automated tests: checks the command line and the MCP server against a sample note.
# Usage: ci-connect-check.sh <Sintr.app>
set -u
BIN="$1/Contents/MacOS/Sintr"
ROOT="$HOME/Library/Application Support/Sintr"
ID="0F6C2D0E-5E5B-4C55-9A57-3C1D2B7A1E01"
mkdir -p "$ROOT/Notes"
cat > "$ROOT/Notes/$ID.json" <<JSON
{"id": "$ID", "title": "Budget review", "created": "2026-10-15T15:00:00Z", "modified": "2026-10-15T15:00:00Z",
 "myNotes": "Travel budget?", "enhanced": "## Decisions\n- We decided to cut the travel budget by 10 percent.",
 "transcript": [{"speaker": "Them", "start": 3, "text": "Let's cut the travel budget."}]}
JSON
run() { perl -e 'alarm 60; exec @ARGV' "$BIN" "$@" 2>&1; }
FAIL=0
check() { # label, haystack, needle
  if grep -qF "$3" <<<"$2"; then echo "ok: $1"; else echo "::error title=$1::expected “$3” in:%0A$(echo "$2" | head -20 | awk 'BEGIN{ORS="%0A"} {print}')"; FAIL=1; fi
}
check "cli list" "$(run --cli list)" "Budget review"
check "cli search" "$(run --cli search travel budget)" "Budget review"
check "cli get" "$(run --cli get 0F6C2D0E --json)" "travel budget"
check "cli folders" "$(run --cli folders)" "No folders."

MCP_IN='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"ci","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list"}
{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"search_notes","arguments":{"query":"travel budget"}}}'
defaults write io.github.mmzeller.Sintr allowAIApps -bool false
OUT=$(printf '%s\n' "$MCP_IN" | perl -e 'alarm 60; exec @ARGV' "$BIN" --mcp 2>/dev/null)
check "mcp initialize" "$OUT" '"protocolVersion":"2025-06-18"'
check "mcp tools" "$OUT" '"name":"search_notes"'
check "mcp off by default" "$OUT" "isn't sharing notes"
LINES=$(grep -c '^{' <<<"$OUT")
[ "$LINES" = "3" ] && echo "ok: three replies" || { echo "::error title=mcp replies::expected 3 lines, got $LINES"; FAIL=1; }
defaults write io.github.mmzeller.Sintr allowAIApps -bool true
OUT=$(printf '%s\n' "$MCP_IN" | perl -e 'alarm 60; exec @ARGV' "$BIN" --mcp 2>/dev/null)
check "mcp search" "$OUT" "Budget review"
defaults delete io.github.mmzeller.Sintr allowAIApps
rm -f "$ROOT/Notes/$ID.json"
echo "::notice title=Command line and MCP::$( [ $FAIL = 0 ] && echo passed || echo failed)"
exit $FAIL
