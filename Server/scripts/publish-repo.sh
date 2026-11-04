#!/bin/bash
# Publishes the package site of one NAS system to GitHub Pages:
#   https://github.com/Romulas-12/fsdrive-packages-<system> -> https://romulas-12.github.io/fsdrive-packages-<system>/
#
# usage: scripts/publish-repo.sh qnap|synology
#   run scripts/build-qpkg.sh [--x86] or scripts/build-spk.sh [--arm] first.
#
# Every publish replaces the history with one commit: the site holds only the latest packages,
# and old packages do not pile up in git.
set -euo pipefail
cd "$(dirname "$0")/.."

SYSTEM=${1:?usage: scripts/publish-repo.sh <system>}
REPO=Romulas-12/fsdrive-packages-$SYSTEM
BASE_URL=https://romulas-12.github.io/fsdrive-packages-$SYSTEM
SITE=build/repo/$SYSTEM

scripts/test-repo.py
scripts/build-repo.py "$SYSTEM" --base-url "$BASE_URL" --out "$SITE"
touch "$SITE/.nojekyll"

cd "$SITE"
git init -q -b main
git add -A
git commit -q -m "Publish $(date -u +%Y-%m-%dT%H:%M:%SZ)"
git push -q -f "https://github.com/$REPO.git" main
echo "published: $BASE_URL/ — checking the live site"
cd - >/dev/null
if [ -f "$SITE/repo.xml" ]; then
    STAMP=$(sed -n 's:.*<cachechk>\(.*\)</cachechk>.*:\1:p' "$SITE/repo.xml")
else
    STAMP=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["published"])' "$SITE/release.json")
fi
scripts/check-repo.py "$BASE_URL" --wait-for "$STAMP"
