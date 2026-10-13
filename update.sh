#!/bin/bash
# Gets the latest Sintr code from GitHub without losing your signing team.
# Usage:  bash ~/Sintr/update.sh      then press Run in Xcode again.
set -uo pipefail
cd "$(dirname "$0")"
PROJECT="Sintr.xcodeproj/project.pbxproj"

if [ ! -d .git ]; then
  printf "\n\033[1;31m%s\033[0m\n" "This copy of Sintr wasn't downloaded with git, so it can't update itself."
  echo "Set it up once with:   git clone https://github.com/mmzeller/Sintr.git ~/Sintr"
  exit 1
fi

# Xcode writes your team into the project file when you pick it under Signing & Capabilities.
# Remember it, undo that one local change so the update applies cleanly, then put it back.
TEAM=$(grep -oE 'DEVELOPMENT_TEAM = [A-Z0-9]{10};' "$PROJECT" | head -1 | grep -oE '[A-Z0-9]{10}' || true)
git checkout -- "$PROJECT" 2>/dev/null || true

printf "\n\033[1m%s\033[0m\n" "Getting the latest Sintr…"
if ! git pull --ff-only; then
  printf "\n\033[1;31m%s\033[0m\n" "Couldn't update. If you changed files in this folder, run:  git stash   then try again."
  exit 1
fi

if [ -n "$TEAM" ]; then
  sed -i '' "s/DEVELOPMENT_TEAM = \"\";/DEVELOPMENT_TEAM = $TEAM;/g" "$PROJECT"
  echo "Kept your signing team ($TEAM)."
fi
printf "\n\033[1m%s\033[0m\n" "Updated. In Xcode, press Run (▶) to install the new version."
