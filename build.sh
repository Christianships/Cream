#!/bin/zsh
# Builds Cream.app and installs it to ~/Applications.
#   ./build.sh          build + install + launch
#   ./build.sh --no-run build + install only
set -euo pipefail
cd "${0:A:h}"

APP=build/Cream.app
DEST="$HOME/Applications/Cream.app"

# The default sounds are other people's recordings, so they aren't in the repo.
# The app refuses to start without them; catch that here instead.
if [[ ! -f Sounds/nk-cream/config.json || ! -f Sounds/mouse/minecraft_click.mp3 ]]; then
  echo "error: default sounds missing (they aren't in the repo; see \"Sounds\" in README.md)" >&2
  echo "  Sounds/nk-cream/config.json          any Mechvibes pack's files go in Sounds/nk-cream/" >&2
  echo "  Sounds/mouse/minecraft_click.mp3     any short click sound, under this name" >&2
  exit 1
fi

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Sounds"

swiftc -O -swift-version 5 -target arm64-apple-macos13.0 \
  -o "$APP/Contents/MacOS/Cream" Sources/*.swift

cp Info.plist "$APP/Contents/"
cp Icon/AppIcon.icns "$APP/Contents/Resources/"   # redraw: see Icon/make-icon.swift
cp -R Sounds/ "$APP/Contents/Resources/Sounds/"

# Sign with the local "Cream Local Signing" certificate when it exists. A stable
# identity keeps the Input Monitoring grant valid across rebuilds; an ad-hoc
# signature changes every build, and macOS then silently stops delivering keys.
IDENTITY=$(security find-identity -p codesigning | awk '/"Cream Local Signing"/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" --identifier dev.christianaguilar.cream "$APP"
[[ -n "$IDENTITY" ]] || echo "warning: ad-hoc signed; re-grant Input Monitoring after each rebuild"

pkill -x Cream 2>/dev/null && sleep 0.5 || true
rm -rf "$DEST" && cp -R "$APP" "$DEST"
echo "Installed $DEST"

# -g: launch in the background so Cream never takes keyboard focus.
[[ "${1:-}" == "--no-run" ]] || open -g "$DEST" --args --background
