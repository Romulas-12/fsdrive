#!/bin/bash
# Builds and signs FSDrive.app (menu bar app + File Provider extension) from the Xcode
# project into build/Release. The same project opens in Xcode for development.
# usage: scripts/build-mac-app.sh [--install]   (--install copies it to /Applications and launches it)
set -euo pipefail
cd "$(dirname "$0")/.."

APP=build/Release/FSDrive.app
# The project signs with the "Apple Development" identity of team BBBH2WC2K8; another
# identity can be given as FSDRIVE_SIGN_IDENTITY.
SIGN=()
[ -n "${FSDRIVE_SIGN_IDENTITY:-}" ] && SIGN=(CODE_SIGN_IDENTITY="$FSDRIVE_SIGN_IDENTITY")

# A fresh link each time: the UUID pin edits the binaries before Xcode signs them, and on
# an incremental build it would edit an already signed one and break its signature.
rm -rf "$APP"
xcodebuild -project FSDrive.xcodeproj -target FSDrive -configuration Release \
    SYMROOT="$PWD/build" OBJROOT="$PWD/build/obj" ${SIGN[@]+"${SIGN[@]}"} build 2>&1 \
    | grep -E "error:|warning: .*FSDrive|BUILD" || true
[ -d "$APP" ] && codesign --verify --deep --strict "$APP" || { echo "build failed" >&2; exit 1; }

# Only the installed copy may be known to the system. A second registered copy with the
# same bundle id lets macOS pin local network access to an old build of the Finder
# extension ("Local network prohibited" until a restart).
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSREGISTER" -u "$PWD/$APP" 2>/dev/null || true
echo "built $APP"

if [ "${1:-}" = "--install" ]; then
    pkill -x FSDrive 2>/dev/null || true
    rm -rf /Applications/FSDrive.app
    cp -R "$APP" /Applications/
    # Copies Xcode built (DerivedData) go too. The extension's UUID is the same in every
    # build, so macOS may still hold local network access for one of them until a restart.
    "$LSREGISTER" -dump | sed -n 's/^path: *\(.*FSDrive\.app\) (0x[0-9a-f]*)$/\1/p' | sort -u | while read -r other; do
        [ "$other" = /Applications/FSDrive.app ] || "$LSREGISTER" -u "$other" 2>/dev/null || true
    done
    "$LSREGISTER" -f /Applications/FSDrive.app
    open /Applications/FSDrive.app
    echo "installed /Applications/FSDrive.app"
fi
