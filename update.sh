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
TEAM=$(sed -nE 's/.*DEVELOPMENT_TEAM = ([A-Z0-9]{10});.*/\1/p' "$PROJECT" | head -1)
git checkout -- "$PROJECT" 2>/dev/null || true
# Xcode also rewrites the list of package versions; let the update replace it.
git checkout -- Sintr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved 2>/dev/null || true

# Anything else changed here (Xcode sometimes rewrites Sintr-Info.plist) is set aside, not
# lost, so the update can apply: "git stash list" shows it, "git stash pop" brings it back.
CHANGED=$(git diff --name-only HEAD 2>/dev/null)
if [ -n "$CHANGED" ]; then
  if git stash push -q -m "Set aside by update.sh on $(date '+%Y-%m-%d %H:%M')"; then
    printf "\n%s\n" "Set aside changes made in this folder, so the update can apply:"
    printf "  %s\n" $CHANGED
    echo "They're kept: git stash list shows them, and git stash pop brings them back."
  fi
fi

printf "\n\033[1m%s\033[0m\n" "Getting the latest Sintr…"
if ! git pull --ff-only; then
  printf "\n\033[1;31m%s\033[0m\n" "Couldn't update. If you changed files in this folder, run:  git stash   then try again."
  exit 1
fi

if [ -n "$TEAM" ]; then
  sed -i '' "s/DEVELOPMENT_TEAM = \"\";/DEVELOPMENT_TEAM = $TEAM;/g" "$PROJECT"
  echo "Kept your signing team ($TEAM)."
fi
printf "\n\033[1m%s\033[0m\n" "Updated. Now rebuild: run make-portable.sh (portable version) or install-mac.sh, or press Run (▶) in Xcode."
