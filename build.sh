#!/bin/bash
# Builds PhotoViewer.app from the Swift package.
#
#   ./build.sh            build .build/app.noindex/PhotoViewer.app
#   ./build.sh --install  ...and copy it to /Applications, register it with LaunchServices
#
# The build copy lives in a ".noindex" folder and is explicitly unregistered, so Finder's
# "Open With" always launches the installed copy in /Applications.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="PhotoViewer"
BUNDLE_ID="com.ikibirdir.PhotoViewer"
VERSION="1.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M%S)"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
STAGING=".build/app.noindex"
APP="$STAGING/$APP_NAME.app"
INSTALLED="/Applications/$APP_NAME.app"

INSTALL=0
for arg in "$@"; do
    case "$arg" in
        --install) INSTALL=1 ;;
        -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
        *) echo "Unknown option: $arg" >&2; exit 1 ;;
    esac
done

echo "==> Building (release)"
swift build -c release --product "$APP_NAME"
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
sed -e "s/__VERSION__/$VERSION/" \
    -e "s/__BUILD__/$BUILD_NUMBER/" \
    -e "s/__BUNDLE_ID__/$BUNDLE_ID/" \
    Resources/Info.plist > "$APP/Contents/Info.plist"
plutil -lint -s "$APP/Contents/Info.plist"
if [ -f Resources/AppIcon.icns ]; then
    cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Never let LaunchServices use the build copy.
"$LSREGISTER" -u "$APP" >/dev/null 2>&1 || true

if [ "$INSTALL" = 1 ]; then
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "==> Quitting the running $APP_NAME"
        pkill -x "$APP_NAME" || true
        for _ in $(seq 1 50); do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.1; done
    fi

    echo "==> Installing to $INSTALLED"
    rm -rf "$INSTALLED"
    ditto "$APP" "$INSTALLED"
    "$LSREGISTER" -f -R -trusted "$INSTALLED"

    # Unregister any other copies LaunchServices may know about (old builds, copies elsewhere).
    mdfind "kMDItemCFBundleIdentifier == '$BUNDLE_ID'" 2>/dev/null | while IFS= read -r path; do
        if [ "$path" != "$INSTALLED" ]; then
            echo "    unregistering stray copy: $path"
            "$LSREGISTER" -u "$path" >/dev/null 2>&1 || true
        fi
    done
    echo "==> Installed $INSTALLED ($VERSION, build $BUILD_NUMBER)"
else
    echo "==> Built $APP (not installed; run ./build.sh --install)"
fi
